%% Copyright (c) 2017  Devin Butterfield
%% 
%% *This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License as
%% published by the Free Software Foundation; either version 3, or
%% (at your option) any later version.
%% 
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%% General Public License for more details.
%% 
%% You should have received a copy of the GNU General Public License
%% along with this program; see the file COPYING.  If not, write to
%% the Free Software Foundation, Inc., 51 Franklin Street, Fifth
%% Floor, Boston, MA 02110-1301, USA.
%% 

%%
%% ALE datalink layer functionality
%%

-module(ale).

-behaviour(gen_fsm).

-include("radio.hrl").

-export([rx/1
        , start_link/0
        , scanning_sound/3
        , sound_2g4g/0
        , send_words/1
        , sound/0
        , scanning_sound/0
        , call/1
        , scanning_call/1
        , call/2
        , scanning_call/2
        , amd/1
        , link_terminate/0
        , link_terminate/1
        , fnctrl/1
        , current_freq/1
        , ctrl_disconnect/0
        , gen_sound/0
        , gen_terminate/2
        , gen_ack/2
        , gen_call/4
        , char_validate38/1
        , list_validate64/1
        , amd_decode/2
        , send_hflink_report/1
        , find_longest_conclusion/2
        , find_longest_conclusion/1
        , conv/2
        , words_to_bin/2
        , test_send_words/1
        , build_ale_address/3
        , tune_radio/2
        , tune_pa/2
        , hflink_reporting/1
        ]).

-export([rx_sound_complete/5]).

-export([init/1
        , handle_event/3
        , handle_sync_event/4
        , handle_info/3
        , terminate/3
        , code_change/4
        , idle/2
        % , tx_sounding/2
        , call_wait_tx_complete/2
        , call_wait_handshake_response/2
        , call_wait_response_tx_complete/2
        , call_linked_wait_terminate/2
        , call_ack/2
        , call_linked/2
        , sounding/2
        , sounding_lbt/2
        , sounding_tune_wait_lbt/2
        ]).

-define(SERVER, ?MODULE).

%% ALE word types (preambles); first 3 MSBs of ALE word
%% TODO: some of these should be configurable (stored in DB)
-define(ALE_WORD_TYPE_DATA 	,	0).
-define(ALE_WORD_TYPE_THRU	,	1).
-define(ALE_WORD_TYPE_TO   	,	2).
-define(ALE_WORD_TYPE_TWAS 	,	3).
-define(ALE_WORD_TYPE_FROM 	,	4).
-define(ALE_WORD_TYPE_TIS  	,	5).
-define(ALE_WORD_TYPE_CMD  	,	6).
-define(ALE_WORD_TYPE_REP  	,	7).

-define(ALE_MAX_ADDRESS_LEN ,   15).
-define(ALE_WORD_LEN       	,	24).
-define(ALE_TX_WORD_LEN    	,	49).
-define(ALE_TA				,	392).
-define(ALE_TRW				,	392).
-define(ALE_DATALINK_TIMEOUT,   ?ALE_TRW * 5).
-define(ALE_DATALINK_EOF	,	3).				%% End of frame marker
-define(ALE_DATALINK_PHA	,	2).				%% Word phase marker
-define(ALE_DATALINK_EOT	,	1).				%% end of transmission marker
-define(ALE_MAX_BER_VAL		,	30.0). 			%% PER inverse of Table A-XIII
-define(ALE_SINAD_UNKNOWN	,	31).			%% Unknown SINAD value
-define(ALE_TT 				, 	3000).			%% slowest tune time
-define(ALE_TTD 			, 	100).			%% transmitter internal latency
-define(ALE_TP 				, 	70).			%% propagation time (70ms MAX)
-define(ALE_TLWW 			,   ?ALE_TRW).
-define(ALE_TTA 			, 	1500).			%% MAX turnaround time
-define(ALE_TRWP			, 	0).				%% redundant word phase delay
-define(ALE_TLD 			, 	1000).			%% late detect delay
-define(ALE_TRD 			, 	100).			%% receiver internal latency
-define(ALE_TWRT 			,  	?ALE_TTD + ?ALE_TP + ?ALE_TLWW + ?ALE_TTA + ?ALE_TRWP + ?ALE_TLD + ?ALE_TRD).
-define(ALE_TWA 			,	300000). 		%% linked state idle timeout
-define(ALE_MAX_AMD_LENGTH  ,   90).
-define(ALE_PA_SWITCH_TIME	,   2000).
-define(ALE_SOUND_LBT_TIMEOUT,	2000).
-define(ALE_SOUNDING_PERIOD	,	60*60*1000).	%% try sounding every 60 minutes
-define(ALE_SOUNDING_RETRY_PERIOD, 5*60*1000). 	%% if abort, retry after 5 minutes of no activity
-define(ALE_INTER_MESSAGE_GAP,  500).           %% 500ms gap between messages

-record(msg_state, {
          status 			= incomplete,
          section 		    = idle, 
          calling 		    = [],
          message 		    = [],
          conclusion 		= [],
          conclusion_list	= [],
          last_type 		= none,
          last_bad_votes 	= 0, 
          word_count 		= 0, 
          sinad 			= ?ALE_SINAD_UNKNOWN,
          frequency 		= 0
         }).

-record(state, {
          fnctrl 			= <<0,0,0,0>>, 
          freq_set_timer 	= none, 
          freq 			    = 0, 
          bad_votes 		= 0, 
          word_count 		= 0,
          call_address	    = [],
          reply_with_address= [],
          wait_for_reply_time=0,
          last_type		    = none,
          message_state	    = #msg_state{},
          call_dir		    = outbound,
          link_state		= unlinked,
          timeout 		    = ?ALE_SOUNDING_PERIOD,
          sounding_channels = [],
          sound_freq		= none,
          sound_timer_ref   = undefined,
          eot               = false,
          transmit_control  = none,
          pa_control        = none,
          tuner_control     = none
         }).

%%%===================================================================
%%% API
%%%===================================================================

%% Load new ALE wo`d that was just received by frontend
rx(Word) ->
    gen_fsm:send_event(ale, {rx_word, Word}).

%% Store current FNCTRL settings
fnctrl(Word) ->
    gen_fsm:send_event(ale, {fnctrl, Word}).

%% Update current frequency
current_freq(Word) ->
    gen_fsm:send_event(ale, {current_freq, Word}).

%% Sounding
sound() ->
    gen_fsm:send_event(ale, {sound}).

scanning_sound() ->
    gen_fsm:send_event(ale, {scanning_sound}).

sound_2g4g() ->
    gen_fsm:send_event(ale, {sound_2g4g}).

%% individual call
call(Address) -> 
    gen_fsm:send_event(ale, {call, string:to_upper(Address), non_scanning,[]}).

%% individual scanning call
scanning_call(Address) ->
    gen_fsm:send_event(ale, {call, string:to_upper(Address), scanning,[]}).

%% individual call with AMD message
call(Address, AMDMessage) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH -> 
    gen_fsm:send_event(ale, {call, string:to_upper(Address), non_scanning, string:to_upper(AMDMessage)});
call(_Address, _AMDMessage) ->
    lager:error("AMD message must be less than ~p", [?ALE_MAX_AMD_LENGTH]),
    error.	

%% AMD message
amd(AMDMessage) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH -> 
    gen_fsm:send_event(ale, {amd, string:to_upper(AMDMessage)});
amd(_AMDMessage) ->
    lager:error("AMD message must be less than ~p", [?ALE_MAX_AMD_LENGTH]),
    error.

%% individual scanning call with AMD message
scanning_call(Address, AMDMessage) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH ->
    gen_fsm:send_event(ale, {call, string:to_upper(Address), scanning, string:to_upper(AMDMessage)});
scanning_call(_Address, _AMDMessage) ->
    lager:error("AMD message must be less than ~p", [?ALE_MAX_AMD_LENGTH]),
    error.	

%% link termination
link_terminate() ->
    gen_fsm:send_event(ale, {link_terminate,[]}).

%% link termination with AMD message
link_terminate(AMDMessage) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH ->
    gen_fsm:send_event(ale, {link_terminate, string:to_upper(AMDMessage)});
link_terminate(_AMDMessage) ->
    lager:error("AMD message must be less than ~p", [?ALE_MAX_AMD_LENGTH]),
    error.	

%% Tell the datalink that ALE tx completed 
tx_complete() ->
    gen_fsm:send_event(ale, {tx_complete}).

%% Control device disconnected
ctrl_disconnect() ->
    gen_fsm:send_all_state_event(ale, {ctrl_disconnect}).

hflink_reporting(true) ->
    radio_db:write_config(hflink_reporting, true);
hflink_reporting(false) ->
    radio_db:write_config(hflink_reporting, false).

%%
%% Radio control TX handling
%%
transmit_control_tx(none, Mode) ->
    %% do nothing, no radio to control
    {ok, Mode};
transmit_control_tx(internal, Mode) ->
    lager:debug("radio control internal not yet implemented"),
    {ok, Mode};
transmit_control_tx(external, Mode) ->
    radio_control_port:tx(Mode).

radio_control_set_freq(none, Freq) ->
    {ok, Freq};
radio_control_set_freq(external, Freq) ->
    radio_control_port:set_freq(Freq).

%%
%% Tuner control handling
%%
tuner_control(none, Mode) ->
    %% do nothing, no radio to control
    {ok, Mode};
tuner_control(external, Mode) ->
    radio_control_port:tuner(Mode).


%%
%% PA control handling
%%
pa_control_set_freq(none, Freq) ->
    {ok, Freq};
pa_control_set_freq(external, Freq) ->
    pa_control_port:set_freq(Freq).
    
%%
%% Handle sounding timer startup
%%
start_sounding_timer(none, _Timeout) ->
    undefined;
start_sounding_timer(external, Timeout) ->
    gen_fsm:send_event_after(Timeout, {scanning_sound});
start_sounding_timer(internal, _Timeout) ->
    undefined.



%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [], []).


init([]) ->
    lager:info("ALE Datalink starting..."),

    %% load up the radio, pa, and tuner control type configuration
    TransmitControlType =   try radio_db:read_config(transmit_control) of
                                TransmitControlConfig -> TransmitControlConfig
                            catch
                                _:_ -> none
                            end,
    PaControlType =  try radio_db:read_config(pa_control) of
                            PaControlConfig -> PaControlConfig
                        catch
                            _:_ -> none
                        end,
    TunerControlType =  try radio_db:read_config(tuner_control) of
                            TunerControlConfig -> TunerControlConfig
                        catch
                            _:_ -> none
                        end,

    %% just in case we're restarting after a crash
    {ok, off} = transmit_control_tx(TransmitControlType, off),
    {ok, scan} = tuner_control(TunerControlType, scan),
    abort_tx(),
    tell_user_eot(),

    %% startup the sounding timer
    SndTimerRef = start_sounding_timer(TransmitControlType, ?ALE_SOUNDING_PERIOD),

    %% OK go idle
    {ok, idle, #state{  sound_timer_ref=SndTimerRef, 
                        transmit_control=TransmitControlType, 
                        pa_control=PaControlType, 
                        tuner_control=TunerControlType}}.

%% ------------------------------------------------------------------
%% gen_fsm Function Definitions
%% ------------------------------------------------------------------
idle({link_terminate,_}, State) ->
    lager:error("not currently linked"),    
    next_state_idle(State);	
idle({current_freq_set,Freq}, State) ->
    lager:debug("setting current Freq=~p", [Freq]),
    {atomic, ok} = radio_db:write_config(current_freq, Freq),
    NewState = State#state{freq_set_timer=none},
    next_state_idle(NewState);
idle({current_freq, Freq}, State=#state{freq_set_timer=none}) ->
    Ref = gen_fsm:send_event_after(500,{current_freq_set,Freq}),
    NewState = State#state{freq_set_timer=Ref},
    next_state_idle(NewState);
idle({current_freq, Freq}, State=#state{freq_set_timer=OldRef}) ->
    gen_fsm:cancel_timer(OldRef),
    Ref = gen_fsm:send_event_after(500,{current_freq_set,Freq}),
    NewState = State#state{freq_set_timer=Ref},
    next_state_idle(NewState);
idle({rx_word, Word}, State=#state{call_address=[], message_state=MessageState}) ->

    NewMessageState = receive_msg(Word, MessageState),

    %% 
    %% FIXME: in the following code, any response must first tune the
    %% transmitter to the freq we heard the guy on. This could be
    %% slow, and maybe a heads up from the frontend could cause retune
    %% prior to receiving the complete message.
    %% 

    case NewMessageState#msg_state.status of 
        complete ->
            %% got a complete message, validate it, then take action
            LastBadVotes = NewMessageState#msg_state.last_bad_votes,
            WordCount = NewMessageState#msg_state.word_count,
            Calling = NewMessageState#msg_state.calling,
            Message = NewMessageState#msg_state.message,
            Conclusion = NewMessageState#msg_state.conclusion,
            Conclusion_List = NewMessageState#msg_state.conclusion_list,

            lager:info("LastBadVotes=~p, WordCount=~p, Calling=~p, Message=~p, Conclusion=~p Conclusion_List=~p",[LastBadVotes,WordCount,Calling,Message,Conclusion,Conclusion_List]),

            BestConclusion = find_longest_conclusion(Conclusion_List),

            Ber = compute_ber(LastBadVotes, WordCount),
            Sinad = NewMessageState#msg_state.sinad,
            Frequency = NewMessageState#msg_state.frequency,

            %%
            %% FIXME: the following will not properly detect selective AnyCall with more than one addressed group
            %% such as TO@A@ REP@B@. Further the message/word validation FSM also requires fix to support 
            %% this sequence.
            %% 

            case {Calling, Message, BestConclusion} of
                {[to|ToAddr], Message, [tis|FromAddr]} ->

                    %%
                    %% heard link request message
                    %%

                    %% decode any possible AMD messages
                    {ok, AMDMessageList} = amd_decode(Message, []),

                    %% handle other message section types here

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(lists:flatten(ToAddr),right,$@),
                    From = string:strip(lists:flatten(FromAddr),right,$@),

                    SelfAddressMatch = radio_db:read_self_address(To),
                    lager:debug("read_self_address returned ~p", [SelfAddressMatch]),

                    case SelfAddressMatch of
                        {error, not_found} ->
                            %% Not for us, just log and report
                            lager:notice("heard call not for us: logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),
                            
                            rx_sound_complete(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),

                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};
                        {ok,{self_address,MyAddress,own,_NetMember,_NetSlot,Channels,WaitForReplyTime}} ->
                            %% Link request is for us
                            lager:notice("got call from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = amd_notify(AMDMessageList),

                            %% handle other message types here

                            %% send ack
                            AckWords = gen_ack(MyAddress, From),
                            ok = send_words(AckWords), %% queue it up in the front end					
                            rx_sound_complete(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),

                            NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            NewState = State#state{ call_dir=inbound, 
                                                    call_address=From, 
                                                    reply_with_address=MyAddress, 
                                                    message_state=#msg_state{}, 
                                                    timeout=NextStateTimeout},
                            {next_state, call_wait_response_tx_complete, NewState, NextStateTimeout};
                        {ok,{self_address,NetAddress,net,NetMember,NetSlot,Channels,WaitForReplyTime}} ->
                            %% This is a net call to NetAddress. Respond with NetMember name in NetSlot!
                            %% NOTE: NetSlot is performed by inserting intermessage gaps prior to response.
                            lager:notice("heard net call from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = amd_notify(AMDMessageList),

                            %%
                            %% FIXME: implement reply to net call, for now just log/report
                            %%

                            % %% send ack
                            % AckWords = gen_ack(NetMember,From),
                            % %% queue up gaps as needed here
                            % ok = send_words(AckWords), %% queue it up in the front end					
                            rx_sound_complete(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),

                            % NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            % NewState = State#state{call_dir=inbound, call_address=From, message_state=#msg_state{}, timeout=NextStateTimeout},
                            % {next_state, call_wait_response_tx_complete, NewState, NextStateTimeout}

                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};

                        {ok,{self_address,"@?",global_allcall,_NetMember,NetSlot,Channels,WaitForReplyTime}} ->
                            %% Immediately switch user to this channel and unmute
                            %% log and report
                            %% don't respond
                            %%
                            lager:notice("Heard Global AllCall from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = amd_notify(AMDMessageList),

                            %%
                            %% FIXME: tell user to switch to this channel and unmute
                            %%

                            %% log / report
                            rx_sound_complete(Frequency, "@?@", [tis|From], {Ber,Sinad}, AMDMessageList),

                            %% no response, stay idle
                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};	                    
                        {ok,{self_address,"@@?",global_anycall,_NetMember,NetSlot,Channels,WaitForReplyTime}} ->
                            %%
                            %% resond in PRN selected slot (NetSlot)
                            %%
                            lager:notice("got Global AnyCall from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = amd_notify(AMDMessageList),

                            %%
                            %% FIXME: implement reply to global anycall call, for now just log/report
                            %%

                            % %% send ack
                            % AckWords = gen_ack(NetMember,From),
                            % %% queue up PRN slot gaps as needed here
                            % ok = send_words(AckWords), %% queue it up in the front end					
                            rx_sound_complete(Frequency, "@@?", [tis|From], {Ber,Sinad}, AMDMessageList),

                            % NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            % NewState = State#state{call_dir=inbound, call_address=From, message_state=#msg_state{}, timeout=NextStateTimeout},
                            % {next_state, call_wait_response_tx_complete, NewState, NextStateTimeout}

                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};                            
                        {ok,{self_address,"",null,_NetMember,_NetSlot,_Channels,_WaitForReplyTime}} ->
                            %% Not for us, just ignore
                            lager:notice("heard test NULL message not for us: logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),
                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState}
                    end;
                {[to|ToAddr], Message, [tws|FromAddr]} ->
                    %% got TWAS message while idle, report

                    %% decode any possible AMD messages
                    {ok, AMDMessageList} = amd_decode(Message, []),

                    %% handle other message types here

                    %% cleanup addresses / strip off any fill characters
                    To = string:strip(lists:flatten(ToAddr),right,$@),
                    From = string:strip(lists:flatten(FromAddr),right,$@),
                    SelfAddressMatch = radio_db:read_self_address(To),

                    case SelfAddressMatch of
                        {error, not_found} ->
                            %% Not for us, just log and report
                            lager:notice("heard call not for us: logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),

                            rx_sound_complete(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),

                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};
                        {ok,{self_address,MyAddress,own,_NetMember,_NetSlot,Channels,WaitForReplyTime}} ->
                            %% Message is for us
                            lager:notice("got TWS message from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = amd_notify(AMDMessageList),

                            %% send ack
                            rx_sound_complete(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),

                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};
                        {ok,{self_address,NetAddress,net,NetMember,NetSlot,Channels,WaitForReplyTime}} ->
                            lager:notice("heard net call TWS from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = amd_notify(AMDMessageList),

                            rx_sound_complete(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),
                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};
                        {ok,{self_address,"@?",global_allcall,_NetMember,NetSlot,Channels,WaitForReplyTime}} ->
                            %% Immediately switch user to this channel and unmute
                            %% log and report
                            %% don't respond
                            lager:notice("Heard Global AllCall from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = amd_notify(AMDMessageList),

                            %% FIXME: tell user to switch to this channel and unmute

                            %% log / report
                            rx_sound_complete(Frequency, "@?@", [tis|From], {Ber,Sinad}, AMDMessageList),

                            %% no response, stay idle
                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};	                    
                        {ok,{self_address,"@@?",global_anycall,_NetMember,NetSlot,Channels,WaitForReplyTime}} ->
                            lager:notice("got Global AnyCall TWS from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = amd_notify(AMDMessageList),

                            rx_sound_complete(Frequency, "@@?", [tis|From], {Ber,Sinad}, AMDMessageList),

                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};                            
                        {ok,{self_address,"",null,_NetMember,_NetSlot,_Channels,_WaitForReplyTime}} ->
                            %% Not for us, just ignore
                            lager:notice("heard test NULL message not for us: logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),
                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState}
                    end;
                % {[to|ToAddr], [], [tws|FromAddr]} ->
                %     %%
                %     %% got terminate or reject message while idle, treat at sounding
                %     %%
                %     %% cleanup addresses / strip off any fill characters
                %     To = string:strip(ToAddr,both,$@),
                %     From = string:strip(lists:flatten(FromAddr),both,$@),
                %     lager:notice("heard termination from -- logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),

                %     %% Freq = radio_db:read_config(current_freq),
                %     rx_sound_complete(Frequency, To, [tws|From], {Ber,Sinad}, []),
                %     %% InitMessageState = #msg_state{},%InitMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                %     NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                %     {next_state, idle, NewState};					
                {[], [], [MType|FromAddr]} ->
                    %%
                    %% got sounding with intact conclusion
                    %%

                    %% cleanup addresses / strip off the fill characters
                    From = string:strip(lists:flatten(FromAddr),both,$@),
                    rx_sound_complete(Frequency, [], [MType|From], {Ber,Sinad}, []),
                    NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=0},
                    {next_state, idle, NewState};
                Others ->
                    lager:warning("idle: improper message sections: ~p",[Others]),
                    next_state_idle(State)
            end;
        incomplete ->
            %% NewMessageState = {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount},
            NewState = State#state{message_state=NewMessageState, timeout=0},
            {next_state, idle, NewState}
    end;
idle({fnctrl, Word}, State) ->
    NewState=State#state{fnctrl=Word}, % replace exiting record for FNCTRL
    next_state_idle(NewState);
idle({sound}, State) ->
    %% We need to cancel the normal sounding timer incase sound/1 was used, since
    %% otherwise, when this sequence completes, a second sounding timer will be scheduled!!
    gen_fsm:cancel_timer(State#state.sound_timer_ref),
    Freq = radio_db:read_config(current_freq),
    {ok, tuned} = tuner_control(State#state.tuner_control, tuned),
    {ok, on} = transmit_control_tx(State#state.transmit_control, on),
    NextTimeout = send_sound(Freq),
    NextState = State#state{link_state=unlinked, call_dir=none, call_address=[], timeout=NextTimeout, sounding_channels=[], sound_freq = Freq, eot=false},    
    {next_state, sounding, NextState, NextTimeout};
idle({sound_2g4g}, State) ->
    %% We need to cancel the normal sounding timer incase sound_2g4g/1 was used, since
    %% otherwise, when this sequence completes, a second sounding timer will be scheduled!!
    gen_fsm:cancel_timer(State#state.sound_timer_ref),
    Freq = radio_db:read_config(current_freq),
    {ok, tuned} = tuner_control(State#state.tuner_control, tuned),
    {ok, on} = transmit_control_tx(State#state.transmit_control, on),
    NextTimeout = send_sound_2g4g(Freq),
    NextState = State#state{link_state=unlinked, call_dir=none, call_address=[], timeout=NextTimeout, sounding_channels=[], sound_freq = Freq, eot=false},    
    {next_state, sounding, NextState, NextTimeout};    
idle({scanning_sound},  State) ->
    %% We need to cancel the normal sounding timer incase scanning_sound/1 was used, since
    %% otherwise, when this sequence completes, a second sounding timer will be scheduled!!
    gen_fsm:cancel_timer(State#state.sound_timer_ref),

    %% Now load up the sounding channel list
    Channels = radio_db:find_auto_channels(),
    [Chan1|_] = Channels,

    %% Next tune the radio and PA
    ChanFreq = tune_radio(State#state.transmit_control, Chan1),
    NextTimeout = ?ALE_PA_SWITCH_TIME,
    NewState = State#state{link_state=unlinked, call_dir=none, call_address=[], timeout=NextTimeout, sounding_channels=Channels, sound_freq = ChanFreq, eot=false},
    {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};   	
idle({call, Address, CallType, AMDMessage}, State) ->
    lager:debug("individual call request"),
    case whereis(backend_handler) of
        undefined -> lager:info("backend_handler not registered");
        _ ->
            Freq = radio_db:read_config(current_freq),	
            {_,[H,_,M,_,S,_,Ms]} = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms(os:timestamp()))),
            Formatted = lists:flatten(["[",H,":",M,":",S,".",Ms,"]","[FRQ ",integer_to_list(Freq), "]","[ALE][TO][",Address,"]"]),
            Event = backend_handler:build_response([{event,ale_ind_call},{data, list_to_binary(Formatted)}]),
            backend_handler ! {data, Event}
    end,

    %% generate a scanning individual call message
    Words = gen_call(?ALE_WORD_TYPE_TIS, Address, CallType, AMDMessage),
    ok = send_words(Words), %% queue it up in the front end	
    NextTimeout = ?ALE_TRW * (length(Words) + 1),
    NewState = State#state{link_state=unlinked, call_dir=outbound, call_address=Address, timeout=NextTimeout, eot=false},
    {next_state, call_wait_tx_complete, NewState, NextTimeout};
idle({tx_complete}, State) ->
    %% ignore it, not an ale transmission
    next_state_idle(State);
idle(timeout, State) ->
    lager:debug("Got timeout in idle state??"),
    % ale:scanning_sound(),
    % NewState = State#state{timeout=?ALE_SOUNDING_PERIOD},
    next_state_idle(State).

send_sound_2g4g(Freq) ->
    case whereis(backend_handler) of
        undefined -> lager:info("no control device is connected");
        _ ->
            {_,[H,_,M,_,S,_,Ms]} = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms(os:timestamp()))),
            Formatted = lists:flatten(["[",H,":",M,":",S,".",Ms,"]","[FRQ ",integer_to_list(Freq), "]","[ALE][SND][SENDING 2G/4G TWS SOUNDING]"]),
            Event = backend_handler:build_response([{event,ale_tx_sound},{data, list_to_binary(Formatted)}]),
            backend_handler ! {data, Event}
    end,  
    %% generate a sounding
    %% XXX TODO: pull channel sets from database
    ChannelSets = "HFNHFL",
    Sound2G4GWords = gen_call(?ALE_WORD_TYPE_TWAS, "HFR", non_scanning, ChannelSets),
    ok = send_words(Sound2G4GWords),    

    %% return the Freq and expected timeout time for this sounding (plus some slop time for the PA switching)
   	?ALE_TRW * length(Sound2G4GWords) + ?ALE_TT + ?ALE_PA_SWITCH_TIME + ?ALE_PA_SWITCH_TIME.

send_sound(Freq) ->
    case whereis(backend_handler) of
        undefined -> lager:info("no control device is connected");
        _ ->
            {_,[H,_,M,_,S,_,Ms]} = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms(os:timestamp()))),
            Formatted = lists:flatten(["[",H,":",M,":",S,".",Ms,"]","[FRQ ",integer_to_list(Freq), "]","[ALE][SND][SENDING TWS SOUNDING]"]),
            Event = backend_handler:build_response([{event,ale_tx_sound},{data, list_to_binary(Formatted)}]),
            backend_handler ! {data, Event}
    end,  
    %% generate a sounding
    %% XXX TODO: pull channel sets from database
    ChannelSets = "HFNHFL",
    Sound2G4GWords = gen_call(?ALE_WORD_TYPE_TWAS, "HFR", non_scanning, ChannelSets),
    ok = send_words(Sound2G4GWords),    
    ok = send_gap(?ALE_INTER_MESSAGE_GAP),
    Words = gen_sound(),
    ok = send_words(Words), %% queue it up in the front end

    %% return the Freq and expected timeout time for this sounding (plus some slop time for the PA switching)
   	?ALE_TRW * length(Words) + length(Sound2G4GWords) + ?ALE_INTER_MESSAGE_GAP + ?ALE_TT + ?ALE_PA_SWITCH_TIME + ?ALE_PA_SWITCH_TIME.

next_timeout(Timeout, _Period) when Timeout =< 10 ->
    %% If timeout already less than (or equal) 10 return it
    Timeout;
next_timeout(Timeout, Period) when Period >= Timeout ->
    %% -10ms to ensure timeout can occur (otherwise the PHA events keep it from timeout)
    %% we use 10 here since often that is that is the best granularity of the OS.
    Timeout - 10;
next_timeout(Timeout, Period) ->
    Timeout - Period.

call_wait_tx_complete({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    %% FIXME: add case fpr ALE_DATALINK_EOT    
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            %% lager:info("call_wait_tx_complete: NextTimeout=~p",[NextTimeout]),
            NewState=State#state{timeout=NextTimeout},
            {next_state, call_wait_tx_complete, NewState, NextTimeout};
        _Other ->
            lager:debug("got rx_word ~8.16.0b while waiting for TX complete!",[Word]),
            {next_state, call_wait_tx_complete, State, Timeout}
		end;
call_wait_tx_complete({tx_complete}, State) ->
    lager:debug("got tx_complete"),
    NewMessageState = #msg_state{},
    NewState = State#state{message_state=NewMessageState, timeout=?ALE_TWRT},
    {next_state, call_wait_handshake_response, NewState, ?ALE_TWRT};
call_wait_tx_complete({scanning_sound}, State=#state{timeout=Timeout}) ->
    lager:debug("got scanning sound event, rescheduling..."),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},
    %%% XXX using Timeout here, effectively resets the tx_complete timeout timer, is there a better way?
    {next_state, call_wait_tx_complete, NewState, Timeout};    
call_wait_tx_complete(timeout, State) ->
    tell_user_eot(),
    lager:error("timeout occurred while waiting for tx_complete"),
    next_state_idle(State).

compute_ber(LastBadVotes, LastWordCount) when LastWordCount > 0 ->
    round(?ALE_MAX_BER_VAL - (float(LastBadVotes) / float(LastWordCount)));
compute_ber(_LastBadVotes, _LastWordCount) ->
    0.0.


tune_radio(none, Chan) ->
    %% no radio (transmitter) to tune
    Chan#channel.frequency;
tune_radio(internal, Chan) ->
    lager:debug("internal tune radio not implemented"),
    Chan#channel.frequency;
tune_radio(external, Chan) ->
    ChanFreq = Chan#channel.frequency,
    FreqCmdType = <<"FA">>,
    FreqCmdTerm = <<";">>,
    FreqBin = list_to_binary(integer_to_list(ChanFreq)),
    FreqCmd = << FreqCmdType/binary, FreqBin/binary, FreqCmdTerm/binary  >>,
    message_server_proc ! {cmd, FreqCmd},    
    {ok, _Ret2} = radio_control_set_freq(external, ChanFreq),
    case whereis(backend_handler) of
        undefined -> lager:info("no control device is connected");
        _ ->
            JSON = jsx:encode(channel:to_json(Chan)),
            Event = backend_handler:build_response([{event,<<"channel_update">>}, {channel,JSON}]),
            backend_handler ! {data, Event}
    end,    
    ChanFreq.

tune_pa(none, Chan) ->
    %% no PA to tune
    Chan#channel.frequency;
tune_pa(internal, Chan) ->
    lager:debug("internal tune PA not implemented"),
    Chan#channel.frequency;
tune_pa(external, Chan) ->
    ChanFreq = Chan#channel.frequency,
    {ok, _Ret2} = pa_control_set_freq(external, ChanFreq),
    ChanFreq.	

%%
%% States for sounding on all specified channels
%%

%% Continue to listen before transmit sounding state (maybe this state is unnecessary???)
%% For now we don't get fast waveform detections, just received words, otherwise timeout and go sound
sounding_lbt({current_freq,Freq}, State) ->
    lager:warning("received user freq change during LBT, abort sounding..."),
    {ok, off} = transmit_control_tx(State#state.transmit_control, off),
    {ok, scan} = tuner_control(State#state.tuner_control, scan),
    abort_tx(),
    tell_user_eot(),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},    
    {next_state, idle, NextState} = next_state_idle(NewState),
    idle({current_freq,Freq}, NextState);
sounding_lbt({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    %% FIXME: add case fpr ALE_DATALINK_EOT    
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState=State#state{timeout=NextTimeout},
            {next_state, sounding_lbt, NewState, NextTimeout};
        _Other ->
            lager:warning("received word during LBT, abort sounding..."),
            {ok, off} = transmit_control_tx(State#state.transmit_control, off), % just in case!
            {ok, scan} = tuner_control(State#state.tuner_control, scan), % just in case
            abort_tx(),            
            tell_user_eot(),
            SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),            
            NewState=State#state{sound_timer_ref=SndTimerRef},    
            %% direcly jump to idle state
            {next_state, idle, NextState} = next_state_idle(NewState),
            idle({rx_word, Word}, NextState)
    end;
sounding_lbt(timeout,  State=#state{sounding_channels=Channels, sound_freq=SndFreq}) ->
    lager:debug("nothing heard, sounding..."),
    {ok, tuned} = tuner_control(State#state.tuner_control, tuned),
    {ok, on} = transmit_control_tx(State#state.transmit_control, on),
    NextTimeout = send_sound(SndFreq),
    NewState = State#state{link_state=unlinked, call_dir=none, call_address=[], timeout=NextTimeout, sounding_channels=Channels, eot=false},
    {next_state, sounding, NewState, NextTimeout}.

tell_user_eot() ->
    case whereis(backend_handler) of
        undefined -> lager:info("no control device is connected");
        _ ->
            EventMsg = backend_handler:build_response([{event,<<"tx_complete">>}]),
            backend_handler ! {data, EventMsg}
    end.

%%
%% Wait for radio and PA to tune while listening for traffic
%%
sounding_tune_wait_lbt(timeout, State=#state{sounding_channels=[]}) ->
    %% no channels left, done with sounding
    tell_user_eot(),
    lager:debug("final retune of PA"),
    Freq = radio_db:read_config(current_freq),
    {ok, _Ret2} = pa_control_set_freq(State#state.pa_control, Freq),	
    next_state_idle(State);
sounding_tune_wait_lbt(timeout, State=#state{sounding_channels=[Chan|Channels]}) ->
    lager:debug("done waiting for tune now LBT..."),

    %% Need extra delay for Hardrock 50, so doing this here, FIXME !!!!
    _ChanFreq = tune_pa(State#state.pa_control, Chan),

    NextTimeout = ?ALE_SOUND_LBT_TIMEOUT,
    NewState = State#state{timeout=NextTimeout, sounding_channels=Channels},
    {next_state, sounding_lbt, NewState, NextTimeout};
sounding_tune_wait_lbt({current_freq,Freq}, State) ->
    lager:warning("received user freq change during sounding_tune_wait_lbt, abort sounding..."),
    {ok, off} = transmit_control_tx(State#state.transmit_control, off), % just in case!
    {ok, scan} = tuner_control(State#state.tuner_control, scan), % just in case
    abort_tx(),
    tell_user_eot(),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),            
    NewState=State#state{sound_timer_ref=SndTimerRef},        
    {next_state, idle, NextState} = next_state_idle(NewState),
    idle({current_freq,Freq}, NextState);
sounding_tune_wait_lbt({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    %% FIXME: add case fpr ALE_DATALINK_EOT
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState=State#state{timeout=NextTimeout},
            {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};
        _Other ->
            lager:warning("rx word received, abort sounding_tune_wait_lbt..."),
            {ok, off} = transmit_control_tx(State#state.transmit_control, off), % just in case!
            {ok, scan} = tuner_control(State#state.tuner_control, scan), % just in case
            abort_tx(),    
            tell_user_eot(),            
            SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),            
            NewState=State#state{sound_timer_ref=SndTimerRef},    
            %% direcly jump to idle state
            {next_state, idle, NextState} = next_state_idle(NewState),
            idle({rx_word, Word}, NextState)
		end.

sounding({current_freq,Freq}, State) ->
    lager:warning("received user freq change during sounding, abort sounding..."),
    {ok, off} = transmit_control_tx(State#state.transmit_control, off), %% just in case
    {ok, scan} = tuner_control(State#state.tuner_control, scan), %% just in case
    abort_tx(),
    tell_user_eot(),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),            
    NewState=State#state{sound_timer_ref=SndTimerRef},
    {next_state, idle, NextState} = next_state_idle(NewState),
    idle({current_freq,Freq}, NextState);
sounding({rx_word, Word}, State=#state{timeout=Timeout, eot=SoundEot}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    %% FIXME: add case fpr ALE_DATALINK_EOT
    case {DataLinkCtrl, SoundEot} of
        {?ALE_DATALINK_EOT, _} ->
            %% Time to turn off transmitter and switch back to RX
            {ok, off} = transmit_control_tx(State#state.transmit_control, off),
            {ok, scan} = tuner_control(State#state.tuner_control, scan),
            % %% And tell user (if connected) that ALE transmission is complete     
            % tell_user_eot(), %%% <<= NOT YET
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState=State#state{timeout=NextTimeout, eot=true},
            %% Stay in this state until we hear our own EOF
            {next_state, sounding, NewState, NextTimeout};
        {?ALE_DATALINK_PHA, _} ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState=State#state{timeout=NextTimeout},
            {next_state, sounding, NewState, NextTimeout};
        {?ALE_DATALINK_EOF, false} ->
            %% We haven't yet received the EOT, so this is probably an inter-message gap
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState=State#state{timeout=NextTimeout},
            {next_state, sounding, NewState, NextTimeout};        
        {?ALE_DATALINK_EOF, true} ->
            %% We already heard the EOT, send complete message to ourself
            tx_complete(),
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState=State#state{timeout=NextTimeout},
            {next_state, sounding, NewState, NextTimeout};
        _Other ->
            lager:debug("got rx_word ~8.16.0b while waiting for TX complete!", [Word]),
            {next_state, sounding, State}            
		end;
sounding({tx_complete}, State=#state{sounding_channels=[]}) ->		
    lager:info("sounding complete..."),
    %% re init the sounding timer for next time
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),            
    Freq = radio_db:read_config(current_freq),
    MatchList = radio_db:find_channel(Freq),
    case MatchList of
        [] ->
            lager:warning("no matching channel found, assuming VFO mode?");
        [ChanRecord|_Rest] ->
            case whereis(backend_handler) of
                undefined -> lager:info("no control device is connected");
                _ ->
                    JSON = jsx:encode(channel:to_json(ChanRecord)),
                    Event = backend_handler:build_response([{event,<<"channel_update">>}, {channel,JSON}]),
                    backend_handler ! {data, Event}
            end
    end,

    %% still need to re-tune to prior user channel, then we're done
    {ok, _Ret2} = radio_control_set_freq(State#state.transmit_control, Freq),
    NextTimeout = ?ALE_PA_SWITCH_TIME,
    NewState = State#state{timeout=NextTimeout, sound_timer_ref=SndTimerRef, sounding_channels=[]},
    {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};
sounding({tx_complete}, State=#state{sounding_channels=[Chan|Channels]}) ->
    % ok = transmit_control_tx(off),
    % ok = tuner_control(scan),
    %% EOT done, switched back to RX, and heard our own EOF
    ChanFreq = tune_radio(State#state.transmit_control, Chan),
    lager:debug("got tx complete, tuning radio for ~p",[ChanFreq]),
    NextTimeout = ?ALE_PA_SWITCH_TIME,
    NewState = State#state{link_state=unlinked, call_dir=none, call_address=[], timeout=NextTimeout, sounding_channels=[Chan|Channels], sound_freq = ChanFreq},
    {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};    
sounding(timeout, State) ->
    {ok, off} = transmit_control_tx(State#state.transmit_control, off),
    {ok, scan} = tuner_control(State#state.tuner_control, scan),
    abort_tx(),
    tell_user_eot(),
    lager:error("timeout occurred while waiting for tx_complete"),
    next_state_idle(State).

%%
%% Wait for handshake response
%% 
call_wait_handshake_response({rx_word, Word}, State=#state{ link_state=LinkState, 
                                                            call_dir=CallDir, 
                                                            call_address=CallAddress, 
                                                            reply_with_address=ReplyWithAddress,
                                                            message_state=MessageState, 
                                                            timeout=Timeout}) ->

    %% process incoming message words
    {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount, {Sinad, _Frequency}} = 
        receive_msg(Word, MessageState),

    % lager:info("call_wait_handshake_response NextTimeout=~p",[NextTimeout]),

    %% decide what to do 
    case Status of 
        complete ->
            % got a complete message, validate it, then take action
            Ber = compute_ber(LastBadVotes, WordCount),
            case {CallDir, Calling, Message, Conclusion} of
                {_, [to|ToAddr], Message, [tws|FromAddr]} ->
                    %% got link rejection message

                    %% decode any possible AMD messages
                    {ok, AMDMessageList} = amd_decode(Message, []),

                    %% Send to user if they are connected
                    ok = amd_notify(AMDMessageList),

                    %% handle other message types here

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = radio_db:read_config(id),

                    case {To, From} of
                        { MyAddress, CallAddress } ->
                            lager:notice("got link rejection from ~p BER: ~p", [FromAddr, Ber]),
                            next_state_idle(State);
                        _Others ->
                            lager:notice("heard termination message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},							
                            NewState = State#state{call_address=CallAddress, message_state=NewMessageState, timeout=Timeout},
                            {next_state, call_wait_handshake_response, NewState, Timeout}							
                    end;
                {outbound, [to|ToAddr], Message, [tis|FromAddr]} ->
                    %% got link response message

                    %% decode any possible AMD messages
                    {ok, AMDMessageList} = amd_decode(Message, []),

                    %% Send to user if they are connected
                    ok = amd_notify(AMDMessageList),

                    %% handle other message types here

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = radio_db:read_config(id),

                    case {LinkState, To, From} of
                        { unlinked, MyAddress, CallAddress } ->
                            lager:notice("[unlinked] got response from ~p BER: ~p", [FromAddr, Ber]),
                            AckWords = gen_ack(ReplyWithAddress, CallAddress),
                            ok = send_words(AckWords), %% queue it up in the front end					
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                            NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            NewState = State#state{link_state=unlinked, call_address=CallAddress, message_state=NewMessageState, timeout=NextStateTimeout},
                            {next_state, call_ack, NewState, NextStateTimeout};
                        { linked, MyAddress, CallAddress } ->
                            lager:notice("[linked] got response from ~p BER: ~p", [FromAddr, Ber]),
                            AckWords = gen_ack(ReplyWithAddress, CallAddress),
                            ok = send_words(AckWords), %% queue it up in the front end									
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                            NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            NewState=State#state{link_state=linked, call_address=CallAddress, message_state=NewMessageState, timeout=NextStateTimeout},
                            {next_state, call_ack, NewState, NextStateTimeout};	
                        _Others ->
                            lager:notice("heard response message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},							
                            NewState = State#state{call_address=CallAddress, message_state=NewMessageState, timeout=Timeout},
                            {next_state, call_wait_handshake_response, NewState, Timeout}
                    end;	
                {inbound, [to|ToAddr], Message, [tis|FromAddr]} ->
                    %% got link ack message

                    %% decode any possible AMD messages
                    {ok, AMDMessageList} = amd_decode(Message, []),

                    %% Send to user if they are connected
                    ok = amd_notify(AMDMessageList),

                    %% handle other message types here

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = radio_db:read_config(id),

                    case {LinkState, To, From} of
                        { unlinked, MyAddress, CallAddress } ->
                            lager:notice("got acknowledge from ~p BER: ~p", [FromAddr, Ber]),
                            % wait for complete
                            % alert user and unmute speaker
                            lager:notice("ALE call handshake complete. ~p", [CallAddress]),
                            lager:debug("TODO: notify HMI of linking"),
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                            NewState=State#state{link_state=linked, call_address=CallAddress, message_state=NewMessageState, timeout=?ALE_TWA},
                            {next_state, call_linked, NewState, ?ALE_TWA};
                        { linked, MyAddress, CallAddress } ->
                            lager:notice("got acknowledge from ~p BER: ~p", [FromAddr, Ber]),
                            lager:notice("ALE message handshake complete. ~p", [CallAddress]),
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                            NewState=State#state{link_state=linked, call_address=CallAddress, message_state=NewMessageState, timeout=?ALE_TWA},
                            {next_state, call_linked, NewState, ?ALE_TWA};							
                        _Others ->
                            lager:notice("heard response message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                            NewState = State#state{call_address=CallAddress, message_state=NewMessageState, timeout=Timeout},
                            {next_state, call_wait_handshake_response, NewState, Timeout}
                    end;									
                {_, [], [], [tws|FromAddr]} ->
                    %% got sounding

                    %% cleanup addresses / strip off the fill characters
                    From = string:strip(lists:flatten(FromAddr),both,$@),
                    Freq = radio_db:read_config(current_freq),
                    rx_sound_complete(Freq, [], [tws|From], {Ber,Sinad}, []),
                    NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                    NewState = State#state{call_address=CallAddress, message_state=NewMessageState, timeout=Timeout},					
                    {next_state, call_wait_handshake_response, NewState, Timeout};					
                Others ->
                    lager:warning("call_wait_handshake_response: improper message sections: ~p",[Others]),
                    NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                    NewState = State#state{call_address=CallAddress, message_state=NewMessageState, timeout=Timeout},
                    {next_state, call_wait_handshake_response, NewState, Timeout}
            end;
        incomplete ->
            NewMessageState = {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount},
            NewState = State#state{call_address=CallAddress, message_state=NewMessageState, timeout=Timeout},
            {next_state, call_wait_handshake_response, NewState, Timeout}
    end;
call_wait_handshake_response(timeout, State=#state{link_state=LinkState}) ->
    case LinkState of
        unlinked ->
            lager:warning("IMPLEMENT ME: call response timeout, alert user"),
            next_state_idle(State);
        linked ->
            lager:warning("incomplete handshake"),
            lager:debug("IMPLEMENT ME: send notification to HMI"),
            NewState = State#state{timeout=?ALE_TWA},			
            {next_state, call_linked, NewState, ?ALE_TWA}
		end.

%%
%% Wait for ACK to complete
%%
call_ack({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    %% FIXME: add case fpr ALE_DATALINK_EOT
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                                                % lager:info("call_ack: NextTimeout=~p",[NextTimeout]),
            NewState=State#state{timeout=NextTimeout},
            {next_state, call_ack, NewState, NextTimeout};
        _Other ->
            lager:warning("got rx_word ~8.16.0b while waiting for TX complete!",[Word]),
            {next_state, call_ack, State, Timeout}
		end;
call_ack({tx_complete}, State=#state{link_state=LinkState, call_address=CallAddress}) ->
    case LinkState of
        unlinked ->
                                                % wait for complete
                                                % alert user and unmute speaker
            lager:notice("ALE call handshake complete. Linked with ~p", [CallAddress]),
            lager:debug("TODO: notify HMI of linking");
        linked ->
            lager:notice("ALE msg handshake complete."),
            lager:debug("TODO: notify HMI of message \"read\"")
    end,
    NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
    NewState=State#state{call_address=CallAddress, message_state=NewMessageState, timeout=?ALE_TWA},
    {next_state, call_linked, NewState, ?ALE_TWA};
call_ack(timeout, State) ->
    lager:error("call_ack: datalink timeout: check modem!"),
    next_state_idle(State).	

%%
%% Wait for transmitted response to complete
%%
call_wait_response_tx_complete({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    %% FIXME: add case fpr ALE_DATALINK_EOT    
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                                                % lager:info("call_wait_response_tx_complete: NextTimeout=~p",[NextTimeout]),
            NewState=State#state{timeout=NextTimeout},
            {next_state, call_wait_response_tx_complete, NewState, NextTimeout};
        _Other ->
            lager:warning("got rx_word ~8.16.0b while waiting for TX complete!", [Word]),
            {next_state, call_wait_response_tx_complete, State, Timeout}
		end;
call_wait_response_tx_complete({tx_complete}, State=#state{call_address=CallAddress}) ->
                                                % wait for complete
    NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
    NewState=State#state{call_address=CallAddress, message_state=NewMessageState, timeout=?ALE_TWRT},
    {next_state, call_wait_handshake_response, NewState, ?ALE_TWRT};
call_wait_response_tx_complete(timeout, State) ->
    lager:error("call_wait_response_tx_complete: datalink timeout: check modem!"),
    next_state_idle(State).

get_msg_type(C1) ->
    <<Type:2,_Rest:5>> = <<C1:7>>,
    case Type of
        0 -> error;
        1 -> cmd_amd;
        2 -> cmd_amd;
        3 -> unsupported
    end.

%% Decode and create list of all AMD messages received within frame (there can be more than one)
amd_decode([], MessageList) ->
    {ok, lists:reverse(MessageList)};
amd_decode([[cmd_amd|Message]|Rest], MessageList) ->
    lager:notice("AMD: ~ts",[Message]),
    amd_decode(Rest, [Message|MessageList]);
amd_decode([_OtherType|Rest], MessageList) ->
    amd_decode(Rest, MessageList).

%% Decode and create list of all AMD messages received within frame (there can be more than one)
amd_notify([]) ->
    ok;
amd_notify([Message|Rest]) ->
    lager:warning("IMPLEMENT ME: send AMD:~p event to HMI if connected", [Message]),
    amd_notify(Rest).


substitute_chars_by_type([cmd_amd|Rest]) when length(Rest) < ?ALE_MAX_AMD_LENGTH ->
    [26,26,26];
substitute_chars_by_type([cmd_amd|_Rest]) ->
    [];	
substitute_chars_by_type([Unsupported|_Rest]) ->
    lager:error("don't know how to substitute for message type ~p",[Unsupported]),
    [].

substitute_chars([CurList|PrevList]) ->
    SubChars = substitute_chars_by_type(CurList),
    SubList = [CurList|SubChars],
    [lists:flatten(SubList)|PrevList].

%% Little function to select the most complete received address (with least
%% missing words) if we receive it multiple times -- like during soundings.

find_longest_conclusion([Addr|Rest]) ->
    find_longest_conclusion(Addr, Rest).

find_longest_conclusion(LongestAddr, []) ->
    LongestAddr;
find_longest_conclusion(LongestAddr, [Addr|Rest]) when length(Addr) > length(LongestAddr) ->
    find_longest_conclusion(Addr, Rest);
find_longest_conclusion(LongestAddr, [_Addr|Rest]) ->
    find_longest_conclusion(LongestAddr, Rest).


                                                % select_most_complete_conclusion(Type, [], New) ->
                                                % 	lager:debug("selecting new address (no prior)"),
                                                % 	[Type, New];
                                                % select_most_complete_conclusion(Type, [Type|Orig], New) when length(Orig) > length(New) ->
                                                % 	lager:debug("selecting original address (new is shorter) ~p ~p", [Type,Orig]),
                                                % 	[Type|Orig];
                                                % select_most_complete_conclusion(Type, [Type|Orig], New) ->
                                                % 	lager:debug("selecting new address (new is same or longer)"),
                                                % 	[Type, New].

%%
%% Receive ALE message, one word at a time. Validate characters, word
%% ordering, collects message sections, and track message state.
%%
receive_msg(Word, MsgState) ->  %{Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount}) ->
    <<DataLinkCtrl:2,BadVotes:6,Type:3,C1:7,C2:7,C3:7>> = <<Word:32>>,
    <<DataLinkCtrl:2,Sinad:5,Frequency:25>> = <<Word:32>>,
    % lager:info("ALE WORD: ~n", [Word]),
    lager:debug("ALE TRACE(~8.16.0b) => DatalinkCtrl: ~p BadVotes: ~p Type: ~p ~c~c~c",[Word, DataLinkCtrl, BadVotes, Type, C1, C2, C3]),

    Message = MsgState#msg_state.message,
    Calling = MsgState#msg_state.calling,
    Conclusion = MsgState#msg_state.conclusion,

    %% FIXME: add case fpr ALE_DATALINK_EOT
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            %% word phase tick (marks place the decoder expected to get a valid word, but didn't)
            lager:debug("got PHA marker"),
            NewWordCount = MsgState#msg_state.word_count + 1,
            NewBadVotes = MsgState#msg_state.last_bad_votes + 48, %% all bits lost	
            case {MsgState#msg_state.section, MsgState#msg_state.last_type, Type} of
                { idle, _, _} ->
                    MsgState;
                { message, _, _ } ->
                    NewMessage = substitute_chars(MsgState#msg_state.message),
                    MsgState#msg_state{	message=NewMessage, 
                                        conclusion=[], 
                                        last_type=Type, 
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};

                _Others -> 
                    % lager:notice("~p",[{Status, Section, Calling, Message, Conclusion, Type, NewBadVotes, NewWordCount, NextTimeout}]),
                    
                    %% XXX FIXME NOTE: Is it "normal" to get stuck in
                    %% a non-idle state waiting for completion??? It
                    %% recovers when any new message is received.
                    MsgState#msg_state{	%last_type=Type,
                      section=idle,
                      conclusion=[], 
                      last_bad_votes=NewBadVotes, 
                      word_count=NewWordCount}

            end;
        ?ALE_DATALINK_EOF ->
            lager:info("got ALE_DATALINK_EOF: Frequency=~p, SINAD=~p", [Frequency, Sinad]),
            MsgState#msg_state{ status=complete, 
                                calling=lists:flatten(Calling), 
                                message=Message, 
                                conclusion_list=[lists:flatten(Conclusion)|MsgState#msg_state.conclusion_list],
                                last_type=Type, 
                                sinad=Sinad, 
                                frequency=Frequency};
        _ ->
            NewWordCount = MsgState#msg_state.word_count + 1,
            NewBadVotes = MsgState#msg_state.last_bad_votes + BadVotes,	
            Section = MsgState#msg_state.section,
            LastType = MsgState#msg_state.last_type,	
            case {Section, LastType, Type} of
                { idle, _, ?ALE_WORD_TYPE_TO } ->
                    %% if invalid chars ignore this word, no state change
                    {Valid, NewChars} = char_validate38([C1,C2,C3]),	
                    NextSection = case Valid of
                        ok -> calling;
                        error -> idle
                    end,
                    MsgState#msg_state{	status=incomplete, 
                                        section=NextSection, 
                                        calling=[to,NewChars], 
                                        message=[], 
                                        conclusion=[],
                                        last_type=Type, 
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};

                { calling, _, ?ALE_WORD_TYPE_TO } ->
                    %% if invalid chars ignore this word, and keep current calling section, else replace with new
                    {Valid, NewChars} = char_validate38([C1,C2,C3]),	
                    NewCalling = case Valid of
                        ok -> [to, NewChars];
                        error -> Calling
                    end,                    
                    MsgState#msg_state{	status=incomplete, 
                                        section=calling, 
                                        calling=NewCalling, 
                                        message=[], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, word_count=NewWordCount};

                { calling, ?ALE_WORD_TYPE_TO, ?ALE_WORD_TYPE_DATA } ->
                    %% if invalid chars ignore this word, and keep current calling section, else replace with new
                    {Valid, NewChars} = char_validate38([C1,C2,C3]),	
                    NewCalling = case Valid of
                        ok -> [Calling|NewChars];
                        error -> Calling
                    end,  
                    MsgState#msg_state{	status=incomplete, 
                                        section=calling, 
                                        calling=NewCalling, 
                                        message=[], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};

                { calling, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_REP } ->
                    %% if invalid chars ignore this word, and keep current calling section, else replace with new
                    {Valid, NewChars} = char_validate38([C1,C2,C3]),	
                    NewCalling = case Valid of
                        ok -> [Calling|NewChars];
                        error -> Calling
                    end,                     
                    MsgState#msg_state{	status=incomplete, 
                                        section=calling, 
                                        calling=NewCalling, 
                                        message=[], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};

                { calling, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_DATA } ->
                    %% if invalid chars ignore this word, and keep current calling section, else replace with new
                    {Valid, NewChars} = char_validate38([C1,C2,C3]),	
                    NewCalling = case Valid of
                        ok -> [Calling|NewChars];
                        error -> Calling
                    end,    					
                    MsgState#msg_state{	status=incomplete, 
                                        section=calling, 
                                        calling=NewCalling,
                                        message=[], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};					

                { _, _, ?ALE_WORD_TYPE_TIS } ->
                    %% if invalid chars ignore this word, no state change
                    {Valid, NewChars} = char_validate38([C1,C2,C3]),	
                    NextSection = case Valid of
                        ok -> conclusion;
                        error -> Section
                    end,                    
                    lager:debug("got TIS word"),			
                    MsgState#msg_state{	status=incomplete, 
                                        section=NextSection, 
                                        conclusion=[tis,NewChars],
                                        conclusion_list=[lists:flatten(MsgState#msg_state.conclusion)|MsgState#msg_state.conclusion_list],
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { _, _, ?ALE_WORD_TYPE_TWAS } ->
                    %% if invalid chars ignore this word, no state change
                    {Valid, NewChars} = char_validate38([C1,C2,C3]),	
                    NextSection = case Valid of
                        ok -> conclusion;
                        error -> Section
                    end,                    
                    lager:debug("got TWAS word"),				
                    MsgState#msg_state{	status=incomplete, 
                                                      section=NextSection, 
                                                      conclusion=[tws,NewChars], 
                                                      conclusion_list=[lists:flatten(MsgState#msg_state.conclusion)|MsgState#msg_state.conclusion_list],
                                                      last_type=Type,
                                                      last_bad_votes=NewBadVotes, 
                                                      word_count=NewWordCount};

                { calling, ?ALE_WORD_TYPE_TWAS, ?ALE_WORD_TYPE_CMD } ->
                    %%% Invalid sequence %%%
                    %% TODO: ignore this word, go IDLE?
                    lager:notice("improper type ~p received",[[?ALE_WORD_TYPE_TWAS, ?ALE_WORD_TYPE_CMD]]),
                    MsgState#msg_state{	status=incomplete, 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};						

                { calling, ?ALE_WORD_TYPE_TIS, ?ALE_WORD_TYPE_CMD } ->
                    %%% Invalid sequence %%%
                    %% TODO: ignore this word, go IDLE?
                    lager:notice("improper type ~p received",[[?ALE_WORD_TYPE_TIS, ?ALE_WORD_TYPE_CMD]]),
                    MsgState#msg_state{	status=incomplete, 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};						

                { calling, _, ?ALE_WORD_TYPE_CMD } ->
                    %% If invalid chars go idle
                    MessageType = get_msg_type(C1),
                    {Valid, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    NextSection = case Valid of
                        ok -> message;
                        error -> idle
                    end,                 

                    %%% Start of first CMD, put into a list of lists
                    MsgState#msg_state{	status=incomplete, 
                                        section=NextSection, 
                                        message=[[MessageType|NewChars]], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, _, ?ALE_WORD_TYPE_CMD } ->
                    %% if invalid chars ignore this word, no state change                     
                    MessageType = get_msg_type(C1),
                    {Valid, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    NewMessage = case Valid of
                        %% another command in the same message section, just prepend it to list of lists
                        ok -> [lists:flatten([MessageType|NewChars])|Message];
                        error -> Message
                    end,                                      
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=NewMessage, 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, ?ALE_WORD_TYPE_CMD, ?ALE_WORD_TYPE_DATA } ->
                    %% if invalid chars ignore this word, no state change
                    MessageType = get_msg_type(C1),
                    {Valid, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    NewMessage = case Valid of
                        ok -> [lists:flatten([CurList|NewChars])|PrevList];
                        error -> Message
                    end,                        
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=NewMessage, 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};					    

                { message, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_REP } ->
                    %% if invalid chars ignore this word, no state change
                    MessageType = get_msg_type(C1),
                    {Valid, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    NewMessage = case Valid of
                        ok -> [lists:flatten([CurList|NewChars])|PrevList];
                        error -> Message
                    end,                       
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=NewMessage, 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_DATA } ->
                    %% if invalid chars ignore this word, no state change
                    MessageType = get_msg_type(C1),
                    {Valid, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    NewMessage = case Valid of
                        ok -> [lists:flatten([CurList|NewChars])|PrevList];
                        error -> Message
                    end,                     
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=NewMessage, 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_DATA } ->
                    %% invalid, but above PHA handling code will have already substituted SUB chars
                    %% if invalid chars ignore this word, no state change
                    MessageType = get_msg_type(C1),
                    {Valid, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    NewMessage = case Valid of
                        ok -> [lists:flatten([CurList|NewChars])|PrevList];
                        error -> Message
                    end,      
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=NewMessage, 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_REP } ->
                    %% invalid, but above PHA handling code will have already substituted SUB chars
                    %% if invalid chars ignore this word, no state change
                    MessageType = get_msg_type(C1),
                    {Valid, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    NewMessage = case Valid of
                        ok -> [lists:flatten([CurList|NewChars])|PrevList];
                        error -> Message
                    end,                     
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=NewMessage,
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    			    

                %% handle missing word DATA -> [REP] -> DATA
                                                % { message, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_DATA } ->
                                                % 	MessageType = get_msg_type(C1),
                                                % 	{ok, NewChars, SubChars} = case MessageType of
                                                % 		error -> {error, [], []};
                                                % 		cmd_amd -> 
                                                % 			{ok, Chars} = list_validate64([C1,C2,C3]),
                                                % 			{ok, Chars, [<<16#2588>>,<<16#2588>>,<<16#2588>>]}; %% <--- substitute block chars
                                                % 		unsupported -> {error, [], []}
                                                % 	end,
                                                % 	[CurList|PrevList] = Message,
                                                % 	SubList = [CurList|SubChars],
                                                %     {incomplete, message, Calling, [lists:flatten([SubList|NewChars])|PrevList], [], Type, NewBadVotes, NewWordCount, NextTimeout};

                %% handle missing word REP -> [DATA] -> REP
                                                % { message, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_REP } ->
                                                % 	MessageType = get_msg_type(C1),
                                                % 	{ok, NewChars, SubChars} = case MessageType of
                                                % 		error -> {error, [], []};
                                                % 		cmd_amd -> 
                                                % 			{ok, Chars} = list_validate64([C1,C2,C3]),
                                                % 			{ok, Chars, [<<16#2588>>,<<16#2588>>,<<16#2588>>]}; %% <--- substitute block chars
                                                % 		unsupported -> {error, [], []}
                                                % 	end,
                                                % 	[CurList|PrevList] = Message,
                                                % 	SubList = [CurList|SubChars],
                                                %     {incomplete, message, Calling, [lists:flatten([SubList|NewChars])|PrevList], [], Type, NewBadVotes, NewWordCount, NextTimeout};

                { conclusion, ?ALE_WORD_TYPE_TIS, ?ALE_WORD_TYPE_DATA } ->
                    {_, NewChars} = char_validate38([C1,C2,C3]),					
                    %% if invalid, NewChars is []
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};					

                { conclusion, ?ALE_WORD_TYPE_TWAS, ?ALE_WORD_TYPE_DATA } ->
                    lager:debug("TWAS -> DATA"),
                    {_, NewChars} = char_validate38([C1,C2,C3]),					
                    %% if invalid, NewChars is []
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};		

                { conclusion, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_REP } ->
                    lager:debug("DATA -> REP"),
                    %% if invalid, NewChars is []
                    {_, NewChars} = char_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};						

                { conclusion, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_DATA } ->
                    lager:debug("REP -> DATA"),
                    %% if invalid, NewChars is []
                    {_, NewChars} = char_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};						
                {idle, 0, 0} ->
                    MsgState#msg_state{	status=incomplete,
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};						
                Others ->
                    lager:debug("improper type ~p received, Conclusion_List=~p",[Others, MsgState#msg_state.conclusion_list]),
                    MsgState#msg_state{	status=incomplete,
                                                % last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount}				
            end
    end.

next_state_idle(State) ->
    NewMessageState = #msg_state{},
    NewState = State#state{link_state=unlinked, call_address=[], message_state=NewMessageState, eot=false},
    {next_state, idle, NewState}.

%%
%% Call linked
%%
%% handle rx soundings
%% handle rx terminate
%%
%% Calling, [], Conclusion
%% Calling, Message, Conclusion
%% [], [], Conclusion
call_linked({call, _Address, _Type, _Message}, State) ->
    %% currently we only support one link at a time (could be a group or net call, but still only one)
    lager:error("already linked"),
    {next_state, call_linked, State, ?ALE_TWA};
call_linked({link_terminate, AMDMessage}, State=#state{call_address=CallAddress}) ->
    lager:notice("terminating link with ~p",[CallAddress]),
    TermWords = gen_terminate(CallAddress, AMDMessage),
    ok = send_words(TermWords),
    NextTimeout = length(TermWords) * (?ALE_TRW * 2),
    NextState = State#state{call_address=CallAddress, timeout=NextTimeout},
    {next_state, call_linked_wait_terminate, NextState, NextTimeout};
call_linked({amd, AMDMessage}, State=#state{call_address=CallAddress}) ->
    Words = gen_call(?ALE_WORD_TYPE_TIS, CallAddress, non_scanning, AMDMessage),
    ok = send_words(Words), %% queue it up in the front end	
    NextTimeout = ?ALE_TRW * (length(Words) + 1),
    NewState = State#state{link_state=linked, call_dir=outbound, call_address=CallAddress, timeout=NextTimeout},
    {next_state, call_wait_tx_complete, NewState, NextTimeout};
call_linked({rx_word, Word}, State=#state{  call_address=CallAddress, 
                                            reply_with_address=ReplyWithAddress,
                                            message_state=MessageState, 
                                            timeout=Timeout}) ->
    {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount,{Sinad,Frequency}} = 
        receive_msg(Word, MessageState),

                                                % lager:info("call_linked NextTimeout=~p",[NextTimeout]),

    case Status of 
        complete ->
                                                % got a complete message, validate it, then take action
            Ber = compute_ber(LastBadVotes, WordCount),
            case {Calling, Message, Conclusion} of
                {[to|ToAddr], Message, [tws|FromAddr]} ->

                    %% got link termination message

                    %% handle any possible AMD messages
                    ok = amd_decode(Message, []),

                    %% handle other message types here

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = radio_db:read_config(id),

                    case {To, From} of
                        { MyAddress, CallAddress } ->
                            lager:notice("got link termination from ~p BER: ~p", [FromAddr, Ber]),
                            next_state_idle(State);
                        _Others ->
                            lager:notice("heard termination message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                            next_state_idle(State)					
                    end;
                {[to|ToAddr], Message, [tis|FromAddr]} ->

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = radio_db:read_config(id),

                    %%
                    %% FIXME: if this was a net call linkup, then we must always respond in the correct slot. One
                    %% solution might be to always use net_slot to decide when to reply, and for individual calls
                    %% this is just 0 (zero).
                    %%

                    case {To, From} of
                        { MyAddress, From } ->
                            %% got message while linked
                            lager:notice("got message from ~p BER: ~p", [FromAddr, Ber]),

                            %% decode any possible AMD messages
                            {ok, AMDMessageList} = amd_decode(Message, []),

                            %% Send to user if they are connected
                            ok = amd_notify(AMDMessageList),

                            %% handle other message types here

                            %% send ack
                            AckWords = gen_ack(ReplyWithAddress,From),
                            ok = send_words(AckWords), %% queue it up in the front end					
                                                % wait for complete
                                                % alert user and unmute speaker
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                            NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            NewState = State#state{link_state=linked, call_dir=inbound, call_address=From, message_state=NewMessageState, timeout=NextStateTimeout},
                            {next_state, call_wait_response_tx_complete, NewState, NextStateTimeout};
                        _Others ->
                            lager:notice("heard message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                                                % NewMessageState = {incomplete, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount},
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                            NewState = State#state{message_state=NewMessageState, timeout=?ALE_TWA},
                            {next_state, call_linked, NewState, ?ALE_TWA}
                    end;	

                {[], [], [tws|FromAddr]} ->
                    %%
                    %% got sounding
                    %%

                    %% cleanup addresses / strip off the fill characters
                    From = string:strip(lists:flatten(FromAddr),both,$@),
                                                % Freq = radio_db:read_config(Frequency),
                    rx_sound_complete(Frequency, [], [tws|From], {Ber,Sinad}, []),
                    NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                    NewState = State#state{call_address=CallAddress, message_state=NewMessageState, timeout=Timeout},					
                    {next_state, call_linked, NewState, Timeout};					
                Others ->
                    %% error, got nothing
                    lager:warning("call_linked: improper message sections: ~p",[Others]),
                    NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                    NewState = State#state{call_address=CallAddress, message_state=NewMessageState, timeout=Timeout},
                    {next_state, call_linked, NewState, Timeout}
            end;
        incomplete ->
            NewMessageState = {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount},
            NewState = State#state{call_address=CallAddress, message_state=NewMessageState, timeout=Timeout},
            {next_state, call_linked, NewState, Timeout}
    end;
call_linked(timeout, State) ->
    lager:notice("link idle timeout with ~p", [State#state.call_address]),
    next_state_idle(State).


call_linked_wait_terminate({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    %% FIXME: add case fpr ALE_DATALINK_EOT    
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                                                % lager:info("call_linked_wait_terminate: NextTimeout=~p",[NextTimeout]),
            NewState=State#state{timeout=NextTimeout},
            {next_state, call_linked_wait_terminate, NewState, NextTimeout};
        _Other ->
            lager:warning("got rx_word ~8.16.0b while waiting for TX complete!",[Word]),
            {next_state, call_linked_wait_terminate, State, Timeout}
		end;
call_linked_wait_terminate({tx_complete}, State) ->
    lager:notice("link terminated"),
    next_state_idle(State);
call_linked_wait_terminate(timeout, State) ->
    lager:error("datalink timeout during link termination"),
    next_state_idle(State).

% tx_sounding({rx_word, Word}, State=#state{timeout=Timeout, eot=SoundEot}) ->
%     <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
%     case {DataLinkCtrl, SoundEot} of 
%         {?ALE_DATALINK_EOT, _} ->
%             %% Time to turn off transmitter and switch back to RX
%             ok = transmit_control_tx(off),
%             ok = tuner_control(scan),
%             %% And tell user (if connected) that ALE transmission is complete     
%             tell_user_eot(),

%             NextTimeout = next_timeout(Timeout, ?ALE_TRW),
%             NewState=State#state{timeout=NextTimeout, eot=true},
%             %% Stay in this state until we hear our own EOF
%             {next_state, tx_sounding, NewState, NextTimeout};
%         {?ALE_DATALINK_PHA, _} ->
%             NextTimeout = next_timeout(Timeout, ?ALE_TRW),
%             NewState=State#state{timeout=NextTimeout},
%             {next_state, tx_sounding, NewState, NextTimeout};
%         {?ALE_DATALINK_EOF, false} ->
%             %% We haven't yet received the EOT, so this is probably an inter-message gap
%             NextTimeout = next_timeout(Timeout, ?ALE_TRW),
%             NewState=State#state{timeout=NextTimeout},
%             {next_state, tx_sounding, NewState, NextTimeout};        
%         {?ALE_DATALINK_EOF, true} ->
%             %% We already heard the EOT, send complete message to ourself
%             tx_complete(),
%             NextTimeout = next_timeout(Timeout, ?ALE_TRW),
%             NewState=State#state{timeout=NextTimeout},
%             {next_state, tx_sounding, NewState, NextTimeout};
%         _Other ->
%             lager:debug("got rx_word while waiting for TX complete!"),
%             {next_state, sounding, State}            
% 		end;
% tx_sounding(timeout, State) ->
%     ok = transmit_control_tx(off),
%     ok = tuner_control(scan),
%     lager:error("timeout occurred while waiting for tx_complete"),
%     next_state_idle(State);      
% tx_sounding({tx_complete}, State) ->
%     next_state_idle(State).

handle_event({ctrl_disconnect}, StateName, State=#state{fnctrl=FnCtrlWord}) ->
    lager:info("got control disconnect"),
    NewState = State#state{fnctrl = FnCtrlWord},
    {next_state, StateName, NewState};
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, ok, StateName, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    lager:notice("got terminate, exiting..."),
                                                % frontend_port:fnctrl(<<0,0,0,16#F0:8>>),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%
%% Function to determine HFLink reporting smeter string. As per Alen Barrow KM4BA alan@pinztrek.com
%% BER icon:
                                                % Smeter icons will be included if the smeter keywork is appended to the
                                                % frame and in the exact engineering format. They specific keywords should
                                                % be sent based on the following BER levels:
                                                %          " smeter4" if ( $line =~ /BER 27|BER 28|BER 29/ );
                                                %          " smeter3" if ( $line =~ /BER 24|BER 25|BER 26/ );
                                                %          " smeter2" if ( $line =~ /BER 21|BER 22|BER 23/ );
                                                %          " smeter1" if ( $line =~ /BER 0\d|BER 1\d|BER 20/ );
get_smeter_string(Ber) when Ber > 29->
    "smeter5";
get_smeter_string(Ber) when Ber > 26->
    "smeter4";        
get_smeter_string(Ber) when Ber > 23->
    "smeter3";
get_smeter_string(Ber) when Ber > 20->
    "smeter2";
get_smeter_string(_Ber) ->
    "smeter1".

send_hflink_report(ReportString) ->
    {ok, Result } = httpc:request(post, {"http://hflink.net/log/postit.php", [],
                                         "application/x-www-form-urlencoded", ReportString},[],[]),
    lager:debug("POST Result: ~p",[Result]).

                                                % -spec get_timestamp() -> integer().
                                                % get_timestamp() ->
                                                %   {Mega, Sec, Micro} = os:timestamp(),
                                                %   (Mega*1000000 + Sec)*1000 + round(Micro/1000).

rx_sound_complete(Freq, To, Conclusion, {Ber, Sinad}, Message) ->
    %% TODO: compute LQA and store in DB?
    %% Filter Id to make sure it is valid??
    [Type|Id] = Conclusion,
    TypeString = string:to_upper(atom_to_list(Type)),
    lager:info("heard: To: ~p From: ~p:~p BER: ~p SINAD: ~p Frequency: ~p, Message: ~p",[To, Type,Id,Ber,Sinad,Freq, Message]),

    MatchList = radio_db:find_channel(Freq),
    Channel = case MatchList of
                  [] ->
                      lager:warning("no matching channel found, assuming VFO mode?"),
                      -1;
                  [ChanRecord|_Rest] ->
                      ChanRecord#channel.id
              end,

    %% TODO get these from external source based on Id ??
    Name = <<"">>, 
    Coordinates = <<"">>, 
    Power = 0, 
    Radio = <<"">>, 
    Controller = <<"">>, 
    Antenna = <<"">>, 

    %% strip any @ filler characters
    CleanId = string:strip(Id,both,$@),

    %% simple way to weed out invalid or partial callsigns
                                                % RegExp = "\\d?[a-zA-Z]{1,2}\\d{1,4}[a-zA-Z]{1,4}",
                                                % case re:run(CleanId, RegExp) of
    case length(CleanId) >= 3 of
        true ->
            {Megasec,Sec,Micro} = os:timestamp(),
            Timestamp = Megasec * 1000000 + Sec,

            %% store it in the contact database
            Contact = 	#contact{	id 			= list_to_binary(CleanId),
                                  time 		= Timestamp,
                                  channel 	= Channel,
                                  frequency 	= Freq,
                                  ber 		= Ber,
                                  sinad 		= Sinad,
                                  name 		= Name,
                                  coordinates = Coordinates,
                                  power 		= Power,
                                  radio 		= Radio,
                                  controller 	= Controller,
                                  antenna 	= Antenna
                                },

            %% TODO: There may be many contacts for a given Id, but on different
            %% frequencies and with different BERs. For now just store the latest for
            %% Id, then if user wants to contact, look into LQA database to determine
            %% best freq and possibly route.
            {atomic, _} = radio_db:write_contact(Contact),
            lager:debug("wrote sounding to db"),

            %% format log message
            {{_Year, _Month, _Day},{H,M,S}} = calendar:now_to_universal_time({Megasec,Sec,Micro}),
            Formatted = case To of
                [] ->
                    io_lib:format("[~.2.0w:~.2.0w:~.2.0w][FRQ ~p][SND][~s][~s][AL0]", [H,M,S,Freq,TypeString,Id]);
                ToAddr ->
                    io_lib:format("[~.2.0w:~.2.0w:~.2.0w][FRQ ~p][TO][~s][~s][~s][AL0]", [H,M,S,Freq,ToAddr,TypeString,Id])
            end,

            lager:notice("~s", [Formatted]),

            %%
            %% "nick=K6DRS&shout=%5B20%3A23%3A35%5D%5BFRQ+18106000%5D%5BSND%5D%5BTWS%5D%5BK6DRS%5D%5BAL0%5D+BER+24+SN+03+smeter3&email=linker&send=&Submit=send"
            %%
            %% POST to: http://hflink.net/log/postit.php
            %% check the DB to determine if HFLink reporting is enabled

            %% get myID from database
            MyId = radio_db:read_config(id),
            ReportHeader = io_lib:format("nick=H2F2N2 ~s&shout=",[MyId]),
            Smeter = get_smeter_string(Ber),
            ReportFooter = io_lib:format("BER+~.2.0w+SN+~.2.0w+~s&email=linker&send=&Submit=send", [Ber, Sinad, Smeter]),
            Report = iolist_to_binary(ReportHeader ++ http_uri:encode(Formatted) ++ Message ++ ReportFooter),
            lager:info("HFLink Report: ~p~n", [Report]),
            ReportEnabled = radio_db:read_config(hflink_reporting),
            case ReportEnabled of
                true ->
                    _Pid = spawn(ale, send_hflink_report, [Report]);
                false ->
                    lager:info("HFLINK Reporting disabled")
            end,

            %% if control device is connected, send it the contact and log event
            case whereis(backend_handler) of
                undefined -> lager:debug("no control device is connected");
                _ ->
                    %% format and send this contact to control device
                    ContactEJSON = contact:to_json(Contact),
                    %% build contact message
                    ContactMsg = backend_handler:build_response([{event,ale_new_contact}, {data, jsx:encode(ContactEJSON)}]),
                    %% send it
                    backend_handler ! {data, ContactMsg},
                    %% build log even message
                    Event = backend_handler:build_response([{event,ale_rx_sound},{data, list_to_binary(Formatted)}]),
                    %% send it
                    backend_handler ! {data, Event}    
            end;
        false ->
            lager:warning("invalid or partial callsign, ignored")
    end.

                                                % HFLinkReportFrame = "nick=K6DRS&shout=" ++ http_uri()
                                                % HFLinkReportFrame = 

char_validate38(Chars) ->
    case re:run(Chars, "^[0-9A-Za-z@?]+$") of
        {match, _ } ->
            {ok, Chars};
        nomatch ->
            lager:warning("invalid character received ~p",[Chars]),
            {error,[]}
    end.

%% 
%% This set of functions is used to find invalid characters in a received ALE
%% string and replace with special SUB characters if invalid.
%%
list_validate64(Chars) ->
    list_validate64(Chars, []).

list_validate64([], Validated) ->
    {ok, lists:reverse(Validated)};
list_validate64([Char|Chars], Validated) ->
    ValidChar = char_validate64(Char),
    list_validate64(Chars, [ValidChar|Validated]).

char_validate64(Char) ->
    case re:run([Char], "^[0-9A-Za-z@ !\"#$%&',()*+,-./:;<>=?^\\[\\]]+$") of
        {match, _ } ->
            Char;
        nomatch ->
            lager:warning("invalid character received ~p",[Char]),
            26
    end.


%% This set of functions is used to build ALE address word given
%% 1-3 address characters.
build_ale_word(_FillChar, Type, Address, Word, 0) ->
    %% swap for bytes for final correct bit ordering
    <<NewWord:24/unsigned-big-integer>> = <<Type:3, Word/bitstring>>,
    {Address, NewWord};
build_ale_word(FillChar, Type, [], Word, Left) ->
    NewWord = << Word/bitstring, FillChar:7 >>,
    build_ale_word(FillChar, Type, [], NewWord, Left-1); 
build_ale_word(FillChar, Type, [A|Address], Word, Left) ->
    NewWord = << Word/bitstring, A:7 >>,
    build_ale_word(FillChar, Type, Address, NewWord, Left-1).

%% This set of functions is used to build a list of ALE address words given
%% up to 15 address characters.
build_ale_words(_FillChar, ?ALE_WORD_TYPE_DATA, _Address, []) ->
    %% can't use DATA as address type
    {error, invalid_address_type};
build_ale_words(_FillChar, ?ALE_WORD_TYPE_THRU, _Address, _Words) ->
    {error, not_implemented};
build_ale_words(_FillChar, _Type, [], Words) ->
    %% all done
    {ok, lists:reverse(Words)};	
build_ale_words(FillChar, ?ALE_WORD_TYPE_DATA, Address, Words) ->
    %% do normal stuff, then call with REP
    {NewAddress, NewWord} = build_ale_word(FillChar, ?ALE_WORD_TYPE_DATA, Address, <<>>, 3),
    build_ale_words(FillChar, ?ALE_WORD_TYPE_REP, NewAddress, [NewWord|Words]);	
build_ale_words(FillChar, ?ALE_WORD_TYPE_REP, Address, Words) ->
    %% do normal stuff, then call with DATA	
    {NewAddress, NewWord} = build_ale_word(FillChar, ?ALE_WORD_TYPE_REP, Address, <<>>, 3),
    build_ale_words(FillChar, ?ALE_WORD_TYPE_DATA, NewAddress, [NewWord|Words]);	
build_ale_words(FillChar, Type, Address, []) ->
    %% first entry point, all others all REP or DATA
    {NewAddress, NewWord} = build_ale_word(FillChar, Type, Address, <<>>, 3),
    build_ale_words(FillChar, ?ALE_WORD_TYPE_DATA, NewAddress, [NewWord]).

%% Entry point for building a list of ALE Address words from a string of up to
%% 15 characters. 
build_ale_address(FillChar, Type, Address) when length(Address) =< ?ALE_MAX_ADDRESS_LEN ->
    {ok, ValidChars } = char_validate38(Address), %% enforce basic ASCII 38 set for ALE
    build_ale_words(FillChar, Type, ValidChars, []);
build_ale_address(_FillChar, _Type, _Address) ->
    {error,[]}.

%% Entry point for building a list of ALE Address words from a string of characters. 
build_ale_message(FillChar, Type, Address) ->
    {ok, ValidChars } = list_validate64(Address), %% enforce extended ASCII 64 set for ALE
    build_ale_words(FillChar, Type, ValidChars, []).

%%
%% Given the specified scan time in millisenconds, whether a reponse is requested/allowed, 
%% and the specified address, generate words for transmission.
%% 
%% scan_time_ms: expected scan time in ms (used to calculate scanning sound phase duration)
%% resp_req: boolean to indicate the type of sounding (TIS or TWAS)
%% address: station address for sounding (15 or less characters) in a null terminated string
%% 
scanning_sound(ScanTimeMs, true, Address) ->
    {ok, Words} = build_ale_address($@, ?ALE_WORD_TYPE_TIS, Address),
    % Words = list_to_binary(Words),
    ScanTimeWords = scanning_sound_rep(Words, length(Words), ScanTimeMs, []),
    lists:flatten(scanning_sound_rep(Words, length(Words) * ?ALE_TA, 4 * length(Words) * ?ALE_TA, ScanTimeWords));
scanning_sound(ScanTimeMs, false, Address) ->
    {ok, Words} = build_ale_address($@, ?ALE_WORD_TYPE_TWAS, Address),
    % Words = list_to_binary(Words),
    ScanTimeWords = scanning_sound_rep(Words, length(Words) * ?ALE_TA, ScanTimeMs, []),
    lists:flatten(scanning_sound_rep(Words, length(Words) * ?ALE_TA, 4 * length(Words) * ?ALE_TA, ScanTimeWords)).

scanning_sound_rep(Words, AddrLenMs, ScanTimeMs, SoundWords) when ScanTimeMs > AddrLenMs ->
    scanning_sound_rep(Words, AddrLenMs, ScanTimeMs - AddrLenMs, [Words|SoundWords]);
scanning_sound_rep(_Words, _AddrLenMs, _ScanTimeMs, SoundWords) ->	
    SoundWords.

words_to_bin([], Bin) ->
    Bin;
words_to_bin([Word|Words], Bin) ->
    NewBin = <<Bin/binary, Word:32/unsigned-little-integer>>,
    words_to_bin(Words, NewBin).

send_gap(GapMs) ->
    MsgCmdType = <<"DT01">>,
    MsgCmdTerm = <<";">>,
    Samples = round((GapMs / 1000.0) * 8000.0),
    MsgBin = <<Samples:32/unsigned-little-integer>>,
    MsgCmd = << MsgCmdType/binary, MsgBin/binary, MsgCmdTerm/binary  >>,
    message_server_proc ! {cmd, MsgCmd},
    ok.

send_words(Words) ->
    MsgCmdType = <<"DT00">>,
    MsgCmdTerm = <<";">>,
    MsgBin = words_to_bin(Words, <<>>),
    MsgCmd = << MsgCmdType/binary, MsgBin/binary, MsgCmdTerm/binary  >>,
    message_server_proc ! {cmd, MsgCmd},
    ok.

abort_tx() ->
    MsgCmd = <<"AB;">>,
    message_server_proc ! {cmd, MsgCmd},
    ok.

gen_sound() ->
    %% get this from the DB / config data
    %%% this should be Trw*num_channels + 2*Trw
    ChannelCount = radio_db:channel_count(),
    ScanTime = ?ALE_TRW * ChannelCount + ?ALE_TRW * 2,
    RespReq = false,
    %% if this isn't set we crash
    MyAddress = radio_db:read_config(id),
    scanning_sound(ScanTime, RespReq, MyAddress).

gen_scanning_call_rep(Words, AddrLenMs, ScanTimeMs, CallWords) when ScanTimeMs > AddrLenMs ->
    gen_scanning_call_rep(Words, AddrLenMs, ScanTimeMs - AddrLenMs, [Words | CallWords]);
gen_scanning_call_rep(_Words, _AddrLenMs, _ScanTimeMs, CallWords) ->	
    CallWords.

%% generate scanning call with optional AMD message
gen_scanning_call(Terminator, ScanTimeMs, Address, MyAddress, []) ->
    %% 1, replicated 1-word TO words
    {ok, ScanToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, lists:sublist(Address,3)),
    ScanTimeCall = gen_scanning_call_rep(ScanToWords, length(ScanToWords) * ?ALE_TA, ScanTimeMs, []),

    %% 2, leading call TO words X2
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, Address),
    LeadingCall = [ToWords, ToWords], %% 2X

    %% 3, from call TIS words
    {ok, FromCall} = build_ale_address($@, Terminator, MyAddress),

    CompleteCall = [ScanTimeCall, LeadingCall, FromCall],
    lists:flatten(CompleteCall);
gen_scanning_call(Terminator, ScanTimeMs, Address, MyAddress, AMDMessage) ->
    %% 1, replicated 1-word TO words
    {ok, ScanToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, lists:sublist(Address,3)),
    ScanTimeCall = gen_scanning_call_rep(ScanToWords, length(ScanToWords) * ?ALE_TA, ScanTimeMs, []),

    %% 2, leading call TO words X2
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, Address),
    LeadingCall = [ToWords, ToWords], %% 2X

    %% 3. Validate then add in the AMD message section
    {ok, MessageWords} = build_ale_message($ , ?ALE_WORD_TYPE_CMD, AMDMessage),	

    %% 4, from call TIS words
    {ok, FromCall} = build_ale_address($@, Terminator, MyAddress),

    CompleteCall = [ScanTimeCall, LeadingCall, MessageWords, FromCall],
    lists:flatten(CompleteCall).

gen_call(Terminator, Address, non_scanning, AMDMessage) ->
    ScanTime = 0,
    MyAddress = radio_db:read_config(id),
    gen_scanning_call(Terminator, ScanTime, Address, MyAddress, AMDMessage);
gen_call(Terminator, Address, scanning, AMDMessage) ->
    ChannelCount = radio_db:channel_count(),
    ScanTime = ?ALE_TRW * ChannelCount + ?ALE_TRW * 2,
    MyAddress = radio_db:read_config(id),
    gen_scanning_call(Terminator, ScanTime, Address, MyAddress, AMDMessage).

gen_ack(ReplyWithAddress,ToAddress) ->
    % MyAddress = radio_db:read_config(id),
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, ToAddress),
    LeadingCall = [ToWords, ToWords],
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TIS, ReplyWithAddress),
    CompleteCall = [LeadingCall, FromCall],
    lists:flatten(CompleteCall).	

gen_terminate(Address, []) ->
    MyAddress = radio_db:read_config(id),
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, Address),
    LeadingCall = [ToWords, ToWords],
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TWAS, MyAddress),
    CompleteCall = [LeadingCall, FromCall],
    lists:flatten(CompleteCall);	
gen_terminate(Address, AMDMessage) ->
    MyAddress = radio_db:read_config(id),
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, Address),
    LeadingCall = [ToWords, ToWords],
    %% Validate then add in the AMD message section
    {ok, MessageWords} = build_ale_message($ , ?ALE_WORD_TYPE_CMD, AMDMessage),
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TWAS, MyAddress),
    CompleteCall = [LeadingCall, MessageWords, FromCall],
    lists:flatten(CompleteCall).

%% just for testing
conv([], NewList) ->
    lists:reverse(NewList);
conv([LH|Rest],NewList) ->
    conv(Rest, [list_to_integer(LH, 16)|NewList]).

test_send_words([ALEWord|Rest]) ->
                                                % lager:info(">> ALE WORD: ~.16b~n", [ALEWord]),
    ale:rx(ALEWord),
    test_send_words(Rest);
test_send_words([]) ->
    ok.
