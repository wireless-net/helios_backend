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

-export([ rx/1
        , tx_complete/0
        , start_link/0
        , gen_scanning_sound/3
        , sound_2g4g/1
        , send_words/1
        , sound/1
        , sound_nmotd/1
        , sound_all/0
        , call/3
        , scanning_call/3
        , call/4
        , scanning_call/4
        , amd/2
        , link_terminate/0
        , link_terminate/1
        , fnctrl/1
        , current_freq/1
        , ctrl_disconnect/0
        , gen_sound/0
        , gen_terminate/3
        , gen_ack/2
        , gen_call/5
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
        , tell_user_eot/0
        , hflink_reporting/1
        , notify_ale_event/2
        , spawn_amd_notify/2
        , amd_notify/2
        , rx_enable/1
        , join/2
        ]).

-export([store_lqa_and_report/5]).

-export([init/1
        , handle_event/3
        , handle_sync_event/4
        , handle_info/3
        , terminate/3
        , code_change/4
        , idle/2
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
-define(ALE_DATALINK_EVT	,	2).				%% Word event marker
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
-define(ALE_TWRT 			,  	?ALE_TT + ?ALE_TTD + ?ALE_TP + ?ALE_TLWW + ?ALE_TTA + ?ALE_TRWP + ?ALE_TLD + ?ALE_TRD).
-define(ALE_TWA 			,	300000). 		%% linked state idle timeout
-define(ALE_MAX_AMD_LENGTH  ,   90).
-define(ALE_PA_SWITCH_TIME	,   2000).
-define(ALE_SOUND_LBT_TIMEOUT,	2000).
-define(ALE_SOUNDING_PERIOD	,	60*60*1000).	%% try sounding every 60 minutes
-define(ALE_SOUNDING_RETRY_PERIOD, 5*60*1000). 	%% if abort, retry after 5 minutes of no activity
-define(ALE_INTER_MESSAGE_GAP,  500).           %% 500ms gap between messages
-define(ALE_SCAN_PREAMBLE_TIME, 10000).         %% scanning call time (preamble length)
-define(ALE_CALL_MAX_RETRIES,   10).            %% Set internal upper limit for sanity

%% TX message tail length to workaround soundcard latency and prevent message truncation
-define(SOUNDCARD_LATENCY, 200).

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
          frequency 		= 0,
          pber_hist         = [0 || _X <- lists:seq(1,?ALQA_STAT_MEASURES)]
         }).

-record(state, {
          fnctrl 			= <<0,0,0,0>>, 
          freq_set_timer 	= none, 
          freq 			    = 0, 
          bad_votes 		= 0, 
          word_count 		= 0,
          other_address	    = [], %% address of other station during call/linkup
          self_address      = [], %% self address called by other station during call/linkup
          reply_with_address= [], %% address to reply with during call/linkup
          wait_for_reply_time=0,
          last_type		    = none,
          message_state	    = #msg_state{},
          call_dir		    = outbound,
          link_state		= unlinked,
          sound_type        = normal,
          timeout 		    = ?ALE_SOUNDING_PERIOD,
          sounding_channels = [],
          sound_freq		= none,
          sound_timer_ref   = undefined,
          transmit_control  = none,
          pa_control        = none,
        %   tuner_control     = none,
          retries           = 0,
          amd               = [],
          call_type         = non_scanning
         }).

%%%===================================================================
%%% API
%%%===================================================================

%% Load new ALE word that was just received by frontend
rx(Word) ->
    gen_fsm:send_event(ale, {rx_word, Word}).

%% Store current FNCTRL settings
fnctrl(Word) ->
    gen_fsm:send_event(ale, {fnctrl, Word}).

%% Update current frequency
current_freq(Word) ->
    gen_fsm:send_event(ale, {current_freq, Word}).

%% Sounding
sound(Frequency) ->
    gen_fsm:send_event(ale, {sound, Frequency}).

sound_all() ->
    gen_fsm:send_event(ale, {sound_all}).

sound_2g4g(Frequency) ->
    gen_fsm:send_event(ale, {sound_2g4g, Frequency}).

sound_nmotd(Frequency) ->
    gen_fsm:send_event(ale, {sound_nmotd, Frequency}).

%% individual scanning call (this version will enventually use LQA and try each channel in order of likelyhood until connect or channels exhausted)
scanning_call(Address, Frequency, Retries) when length(Address) =< ?ALE_MAX_ADDRESS_LEN andalso length(Address) > 0 andalso Retries =< ?ALE_CALL_MAX_RETRIES ->
    gen_fsm:send_event(ale, {call, string:to_upper(Address), Frequency, scanning,[], Retries});
scanning_call(_Address, _Frequency, _Retries) ->
    lager:error("Invalid parameters"),
    error.

%% individual scanning call with AMD message
scanning_call(Address, Frequency, AMDMessage, Retries) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH andalso length(Address) =< ?ALE_MAX_ADDRESS_LEN andalso length(Address) > 0 ->
    gen_fsm:send_event(ale, {call, string:to_upper(Address), Frequency, scanning, string:to_upper(AMDMessage), Retries});
scanning_call(_Address, _Frequency, _AMDMessage, _Retries) ->
    lager:error("Invalid length for address or AMD message"),
    error.	

%% individual call (this version will enventually use LQA and try each channel in order of likelyhood until connect or channels exhausted)
call(Address, Frequency, Retries) when length(Address) =< ?ALE_MAX_ADDRESS_LEN andalso length(Address) > 0 andalso Retries =< ?ALE_CALL_MAX_RETRIES ->
    gen_fsm:send_event(ale, {call, string:to_upper(Address), Frequency, non_scanning,[], Retries});
call(_Address, _Frequency, _Retries) ->
    lager:error("Invalid parameters"),
    error.

%% individual call with AMD message (this version will enventually use LQA and try each channel in order of likelyhood until connect or channels exhausted)
call(Address, Frequency, AMDMessage, Retries) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH andalso length(Address) =< ?ALE_MAX_ADDRESS_LEN andalso length(Address) > 0 andalso Retries =< ?ALE_CALL_MAX_RETRIES -> 
    gen_fsm:send_event(ale, {call, string:to_upper(Address), Frequency, non_scanning, string:to_upper(AMDMessage), Retries});
call(_Address, _Frequency, _AMDMessage, _Retries) ->
    lager:error("Invalid parameters"),
    error.	

%% AMD message
amd(AMDMessage, Retries) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH andalso Retries =< ?ALE_CALL_MAX_RETRIES -> 
    gen_fsm:send_event(ale, {amd, string:to_upper(AMDMessage), Retries});
amd(_AMDMessage, _Retries) ->
    lager:error("Invalid parameters"),
    error.

%% link termination
link_terminate() ->
    gen_fsm:send_event(ale, {link_terminate,[]}).

%% link termination with AMD message
link_terminate(AMDMessage) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH ->
    gen_fsm:send_event(ale, {link_terminate, string:to_upper(AMDMessage)});
link_terminate(_AMDMessage) ->
    lager:error("Invalid length for address or AMD message"),
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
%% Handle sounding timer startup
%%
start_sounding_timer(none, _Timeout) ->
    undefined;
start_sounding_timer(external, Timeout) ->
    gen_fsm:send_event_after(Timeout, {sound_all});
start_sounding_timer(internal, _Timeout) ->
    undefined.

%%
%% Helper for enabling/disabling receiver
%%
rx_enable(true) ->
    RxEnable = <<"FC4026531841;">>,
    message_server_proc ! {cmd, RxEnable};
rx_enable(false) ->
    RxDisable = <<"FC4026531840;">>,
    message_server_proc ! {cmd, RxDisable}.

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
    % TunerControlType =  try radio_db:read_config(tuner_control) of
    %                         TunerControlConfig -> TunerControlConfig
    %                     catch
    %                         _:_ -> none
    %                     end,

    %% just in case we're restarting after a crash
    {ok, off} = radio_control_port:transmit_control(TransmitControlType, off),
    %{ok, scan} = tuner_control(TunerControlType, scan),
    
    %% turn on the receiver (only for use with external transmitters)
    rx_enable(true),

    % abort_tx(),
    % spawn_tell_user_eot(),

    %% startup the sounding timer to fire in the retry period (5-min after startup)
    SndTimerRef = start_sounding_timer(TransmitControlType, ?ALE_SOUNDING_PERIOD),

    %% OK go idle
    {ok, idle, #state{  sound_timer_ref=SndTimerRef, 
                        transmit_control=TransmitControlType, 
                        pa_control=PaControlType}}.
                        % tuner_control=TunerControlType}}.

%% helper function to select between default or programmed TWRT timeout
select_wait_for_reply_time(default) ->
    ?ALE_TWRT;
select_wait_for_reply_time(WaitForReplyTime) ->
    WaitForReplyTime.

%% Used to notify user control device of an ALE event
notify_ale_event(Event, Data) ->
    case whereis(backend_handler) of
        undefined -> lager:info("backend_handler not registered");
        _ ->
            % lager:debug("~p",[[{event,Event},{data, Data}]]),
            Msg = backend_handler:build_response([{event,Event},Data]),
            backend_handler ! {data, Msg}
    end.    

spawn_notify_ale_event(Event, Data) ->
    _Pid = spawn(ale, notify_ale_event, [Event, Data]).

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
    erlang:cancel_timer(OldRef),
    Ref = gen_fsm:send_event_after(500,{current_freq_set,Freq}),
    NewState = State#state{freq_set_timer=Ref},
    next_state_idle(NewState);
idle({rx_word, Word}, State=#state{other_address=[], message_state=MessageState, transmit_control=TxCtrlType}) ->
    NewMessageState = receive_msg(Word, MessageState),

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
                    ToSelfAddressMatch = radio_db:read_self_address(To),
                    FromSelfAddressMatch = radio_db:read_self_address(From),

                    case {ToSelfAddressMatch, FromSelfAddressMatch} of
                        {_, {ok,{self_address,_MyAddress,own,_NetMember,_NetSlot,_Channels,_WaitForReplyTime}}} ->
                            lager:debug("heard my own transmission..."),
                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};                            
                        {{error, not_found}, {error, not_found}} ->
                            %% Not for us, just log and report
                            lager:notice("heard call not for us: logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),
                            
                            spawn_store_lqa_and_report(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),

                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};
                        {{ok,{self_address,MyAddress,own,_NetMember,_NetSlot,_Channels,WaitForReplyTime}},_} ->
                            %% Link request is for us
                            lager:notice("got call from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),

                            %% handle other message types here

                            %% log/report		
                            spawn_store_lqa_and_report(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),

                            case TxCtrlType of
                                none ->
                                    NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                                    {next_state, idle, NewState};                            
                                _ ->
                                    %% stop the sounding timer
                                    erlang:cancel_timer(State#state.sound_timer_ref),

                                    %% turn off the receiver (only for use with external transmitters)
                                    % rx_enable(false),

                                    %% Tune the transmitter and PA
                                    MatchList = radio_db:find_channel(Frequency),
                                    case MatchList of
                                        [] ->
                                            lager:warning("no matching channel found, assuming VFO mode?");
                                        [ChanRecord|_Rest] ->
                                            Frequency = radio_control_port:tune_transmitter(State#state.transmit_control, ChanRecord),
                                            Frequency = pa_control_port:tune_pa(State#state.transmit_control, ChanRecord),
                                            ok = radio_control_port:transmitter_mode(State#state.transmit_control, ChanRecord)
                                        end,

                                    %% turn on the transmitter
                                    %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
                                    {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),

                                    %% send ack
                                    AckWords = gen_ack(From, MyAddress),
                                    ok = send_words(AckWords), %% queue it up in the front end			
                                    %% Workaround for soundcard buffer latency, without it we may truncate our message
                                    %% by turning off the TX before the sound is fully played out.
                                    ok = send_gap(?SOUNDCARD_LATENCY),

                                    %% select the wait for reply time we got from the database
                                    NewWaitForReplyTime = select_wait_for_reply_time(WaitForReplyTime),

                                    %% set the wait for TX complete timeout
                                    NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),

                                    NewState = State#state{ call_dir=inbound, 
                                                            self_address=MyAddress,
                                                            other_address=From,
                                                            reply_with_address=MyAddress,
                                                            wait_for_reply_time=NewWaitForReplyTime, 
                                                            message_state=#msg_state{}, 
                                                            timeout=NextStateTimeout},
                                    {next_state, call_wait_response_tx_complete, NewState}%%, NextStateTimeout}
                                end;
                        {{ok,{self_address,_NetAddress,net,_NetMember,_NetSlot,_Channels, WaitForReplyTime}},_} ->
                            %% This is a net call to NetAddress. Respond with NetMember name in NetSlot!
                            %% NOTE: NetSlot is performed by inserting intermessage gaps prior to response.
                            lager:notice("heard net call from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),

                            %%
                            %% FIXME: implement reply to net call, for now just log/report
                            %%

                            % %% send ack
                            % AckWords = gen_ack(NetMember,From),
                            % %% queue up gaps as needed here
                            % ok = send_words(AckWords), %% queue it up in the front end					

                            % NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            % NewState = State#state{call_dir=inbound, other_address=From, message_state=#msg_state{}, timeout=NextStateTimeout},
                            % {next_state, call_wait_response_tx_complete, NewState, NextStateTimeout}

                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};

                        {{ok,{self_address,"@?",global_allcall,_NetMember,_NetSlot,_Channels,WaitForReplyTime}},_} ->
                            %% Immediately switch user to this channel and unmute
                            %% log and report
                            %% don't respond
                            %%
                            lager:notice("Heard Global AllCall from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, "@?@", [tis|From], {Ber,Sinad}, AMDMessageList),

                            %%
                            %% FIXME: tell user to switch to this channel and unmute
                            %%


                            %% no response, stay idle
                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};	                    
                        {{ok,{self_address,"@@?",global_anycall,_NetMember,NetSlot,Channels,WaitForReplyTime}},_} ->
                            %%
                            %% resond in PRN selected slot (NetSlot)
                            %%
                            lager:notice("got Global AnyCall from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, "@@?", [tis|From], {Ber,Sinad}, AMDMessageList),

                            %%
                            %% FIXME: implement reply to global anycall call, for now just log/report
                            %%

                            % %% send ack
                            % AckWords = gen_ack(NetMember,From),
                            % %% queue up PRN slot gaps as needed here
                            % ok = send_words(AckWords), %% queue it up in the front end					

                            % NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            % NewState = State#state{call_dir=inbound, other_address=From, message_state=#msg_state{}, timeout=NextStateTimeout},
                            % {next_state, call_wait_response_tx_complete, NewState, NextStateTimeout}

                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};                            
                        {ok,{self_address,"",null,_NetMember,_NetSlot,_Channels,_WaitForReplyTime}} ->
                            %% Not for us, just ignore
                            lager:notice("heard test NULL message not for us: logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),
                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
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
                    ToSelfAddressMatch = radio_db:read_self_address(To),
                    FromSelfAddressMatch = radio_db:read_self_address(From),

                    case {ToSelfAddressMatch, FromSelfAddressMatch} of
                        {_, {ok,{self_address,_MyAddress,own,_NetMember,_NetSlot,_Channels,_WaitForReplyTime}}} ->
                            lager:debug("heard my own transmission??"),
                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};                    
                        {{error, not_found},{error, not_found}} ->
                            %% Not for us, just log and report
                            lager:notice("heard call not for us: logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, To, [tws|From], {Ber,Sinad}, AMDMessageList),

                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};
                        {{ok,{self_address,MyAddress,own,_NetMember,_NetSlot,Channels,WaitForReplyTime}},_} ->
                            %% Message is for us
                            lager:notice("got TWS message from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, To, [tws|From], {Ber,Sinad}, AMDMessageList),

                            %% send ack

                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};
                        {{ok,{self_address,NetAddress,net,NetMember,NetSlot,Channels,WaitForReplyTime}},_} ->
                            lager:notice("heard net call TWS from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, To, [tws|From], {Ber,Sinad}, AMDMessageList),
                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};
                        {{ok,{self_address,"@?",global_allcall,_NetMember,NetSlot,Channels,WaitForReplyTime}},_} ->
                            %% Immediately switch user to this channel and unmute
                            %% don't respond
                            lager:notice("Heard Global AllCall from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, "@?@", [tws|From], {Ber,Sinad}, AMDMessageList),

                            %% FIXME: tell user to switch to this channel and unmute

                            %% no response, stay idle
                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};	                    
                        {{ok,{self_address,"@@?",global_anycall,_NetMember,NetSlot,Channels,WaitForReplyTime}},_} ->
                            lager:notice("got Global AnyCall TWS from ~p BER: ~p", [From, Ber]),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, "@@?", [tws|From], {Ber,Sinad}, AMDMessageList),

                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};                            
                        {{ok,{self_address,"",null,_NetMember,_NetSlot,_Channels,_WaitForReplyTime}},_} ->
                            %% Not for us, just ignore
                            lager:notice("heard test NULL message not for us: logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),
                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState}
                    end;
                {[], [], [MType|FromAddr]} ->
                    %%
                    %% got sounding with intact conclusion
                    %%
                    From = string:strip(lists:flatten(FromAddr),right,$@),
                    SelfAddressMatch = radio_db:read_self_address(From),                    
                    case SelfAddressMatch of
                        {error, not_found} ->
                            lager:debug("got sounding not from us"),
                            %% Heard normal sounding -- not from us

                            %% cleanup addresses / strip off the fill characters
                            From = string:strip(lists:flatten(FromAddr),right,$@),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, [], [MType|From], {Ber,Sinad}, []),
                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState};
                        {ok,{self_address,MyAddress,own,_NetMember,_NetSlot,_Channels,WaitForReplyTime}} ->
                            %% it's from us, don't report
                            lager:debug("[IDLE] sounding is from us..."),
                            NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                            {next_state, idle, NewState}
                    end;
                Others ->
                    lager:warning("idle: improper message sections: ~p",[Others]),
                    next_state_idle(State)
            end;
        incomplete ->
            NewState = State#state{message_state=NewMessageState, timeout=0},
            {next_state, idle, NewState}
    end;
idle({fnctrl, Word}, State) ->
    %% FIXME: is this deprecated????
    NewState=State#state{fnctrl=Word},
    next_state_idle(NewState);
idle({sound, Frequency}, State=#state{transmit_control=TxCtrlType}) ->
    case TxCtrlType of
        none ->
            lager:error("Cannot sound with no transmit control defined!"),
            next_state_idle(State);
        _ ->
            %% We need to cancel the normal sounding timer incase sound/1 was used, since
            %% otherwise, when this sequence completes, a second sounding timer will be scheduled!!        
            erlang:cancel_timer(State#state.sound_timer_ref),
            % Freq = radio_db:read_config(current_freq),

            %% turn off the receiver (only for use with external transmitters)
            % rx_enable(false),
            
            %% Tune the transmitter and PA
            MatchList = radio_db:find_channel(Frequency),
            case MatchList of
                [] ->
                    lager:warning("no matching channel found, assuming VFO mode?");
                [ChanRecord|_Rest] ->
                    Frequency = radio_control_port:tune_transmitter(State#state.transmit_control, ChanRecord),
                    Frequency = pa_control_port:tune_pa(State#state.transmit_control, ChanRecord),
                    ok = radio_control_port:transmitter_mode(State#state.transmit_control, ChanRecord)
                end,    

            %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
            {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),
            
            NextTimeout = send_sound(Frequency),
            NextState = State#state{link_state=unlinked, call_dir=none, other_address=[], timeout=NextTimeout, sounding_channels=[], sound_freq = Frequency},
            {next_state, sounding, NextState}%%, NextTimeout}
        end;    
idle({sound_2g4g, Frequency}, State=#state{transmit_control=TxCtrlType}) ->
    case TxCtrlType of
        none ->
            lager:error("Cannot sound with no transmit control defined!"),
            next_state_idle(State);
        _ ->    
            %% We need to cancel the normal sounding timer incase sound_2g4g/1 was used, since
            %% otherwise, when this sequence completes, a second sounding timer will be scheduled!!
            erlang:cancel_timer(State#state.sound_timer_ref),

            %% turn off the receiver (only for use with external transmitters)
            % rx_enable(false),

            %% Tune the transmitter and PA
            MatchList = radio_db:find_channel(Frequency),
            case MatchList of
                [] ->
                    lager:warning("no matching channel found, assuming VFO mode?");
                [ChanRecord|_Rest] ->
                    Frequency = radio_control_port:tune_transmitter(State#state.transmit_control, ChanRecord),
                    Frequency = pa_control_port:tune_pa(State#state.transmit_control, ChanRecord),
                    ok = radio_control_port:transmitter_mode(State#state.transmit_control, ChanRecord)
                end,    

            %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
            {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),

            NextTimeout = send_sound_2g4g(Frequency),
            NextState = State#state{link_state=unlinked, call_dir=none, other_address=[], timeout=NextTimeout, sounding_channels=[], sound_freq = Frequency},    
            {next_state, sounding, NextState}%%, NextTimeout}
    end;
idle({sound_nmotd, Frequency}, State=#state{transmit_control=TxCtrlType}) ->
    case TxCtrlType of
        none ->
            lager:error("Cannot sound NMOTD with no transmit control defined!"),
            next_state_idle(State);
        _ ->    
            %% We need to cancel the normal sounding timer incase sound_2g4g/1 was used, since
            %% otherwise, when this sequence completes, a second sounding timer will be scheduled!!
            erlang:cancel_timer(State#state.sound_timer_ref),

            %% Tune the transmitter and PA
            MatchList = radio_db:find_channel(Frequency),
            case MatchList of
                [] ->
                    lager:warning("no matching channel found, assuming VFO mode?");
                [ChanRecord|_Rest] ->
                    Frequency = radio_control_port:tune_transmitter(State#state.transmit_control, ChanRecord),
                    Frequency = pa_control_port:tune_pa(State#state.transmit_control, ChanRecord),
                    ok = radio_control_port:transmitter_mode(State#state.transmit_control, ChanRecord)
                end,    

            %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
            {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),

            NextTimeout = send_sound_nmotd(Frequency),
            NextState = State#state{link_state=unlinked, call_dir=none, other_address=[], timeout=NextTimeout, sounding_channels=[], sound_freq = Frequency},    
            {next_state, sounding, NextState}%%, NextTimeout}
    end;
idle({nmotd_all},  State=#state{transmit_control=TxCtrlType}) ->
    case TxCtrlType of
        none ->
            lager:error("Cannot send NMOTD with no transmit control defined!"),
            next_state_idle(State);
        _ ->
            %% We need to cancel the normal sounding timer incase sound_all/1 was used, since
            %% otherwise, when this sequence completes, a second sounding timer will be scheduled!!        
            erlang:cancel_timer(State#state.sound_timer_ref),
            %% Now load up the sounding channel list
            Channels = radio_db:find_auto_channels(),
            [Chan1|_] = Channels,
            %% Next tune the radio and PA
            ChanFreq = radio_control_port:tune_transmitter(State#state.transmit_control, Chan1),
            ok = radio_control_port:transmitter_mode(State#state.transmit_control, Chan1),            
            NextTimeout = ?ALE_PA_SWITCH_TIME,
            NewState = State#state{link_state=unlinked, sound_type=nmotd, call_dir=none, other_address=[], timeout=NextTimeout, sounding_channels=Channels, sound_freq = ChanFreq},
            {next_state, sounding_tune_wait_lbt, NewState, NextTimeout}
        end;
idle({sound_all},  State=#state{transmit_control=TxCtrlType}) ->
    case TxCtrlType of
        none ->
            lager:error("Cannot sound with no transmit control defined!"),
            next_state_idle(State);
        _ ->
            %% We need to cancel the normal sounding timer incase sound_all/1 was used, since
            %% otherwise, when this sequence completes, a second sounding timer will be scheduled!!        
            erlang:cancel_timer(State#state.sound_timer_ref),
            %% Now load up the sounding channel list
            Channels = radio_db:find_auto_channels(),
            [Chan1|_] = Channels,
            %% Next tune the radio and PA
            ChanFreq = radio_control_port:tune_transmitter(State#state.transmit_control, Chan1),
            ok = radio_control_port:transmitter_mode(State#state.transmit_control, Chan1),            
            NextTimeout = ?ALE_PA_SWITCH_TIME,
            NewState = State#state{link_state=unlinked, sound_type=normal, call_dir=none, other_address=[], timeout=NextTimeout, sounding_channels=Channels, sound_freq = ChanFreq},
            {next_state, sounding_tune_wait_lbt, NewState, NextTimeout}
        end;
idle({call, Address, Frequency, CallType, AMDMessage, Retries}, State=#state{transmit_control=TxCtrlType}) ->
    case TxCtrlType of
        none ->
            lager:error("Cannot sound with no transmit control defined!"),
            next_state_idle(State);
        _ ->
            lager:debug("individual call request"),

            %% TODO replace this with call to self_address database
            SelfAddress = radio_db:read_config(id),

            %% TODO: decide what to do with channels, Type, etc.
            OtherAddressMatch = radio_db:read_other_address(Address),

            %% for now, we're only using this lookup to determine waitforreplytime, later
            %% channels, netmember, slots, etc. may be needed
            NewWaitForReplyTime = case OtherAddressMatch of
                {error, not_found} ->
                    %% Calling station not in our database, use defaults
                    select_wait_for_reply_time(default);
                {ok,{self_address,Address,Type,NetMember,_NetSlot,Channels,WaitForReplyTime}} ->
                    %% found station in the database, use it's parameters
                    select_wait_for_reply_time(WaitForReplyTime)
            end,

            erlang:cancel_timer(State#state.sound_timer_ref),

            %% Tune the transmitter and PA
            MatchList = radio_db:find_channel(Frequency),
            case MatchList of
                [] ->
                    lager:warning("no matching channel found, assuming VFO mode?");
                [ChanRecord|_Rest] ->
                    Frequency = radio_control_port:tune_transmitter(State#state.transmit_control, ChanRecord),
                    Frequency = pa_control_port:tune_pa(State#state.transmit_control, ChanRecord),
                    ok = radio_control_port:transmitter_mode(State#state.transmit_control, ChanRecord)
                end,

            %% turn on the transmitter
            %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
            {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),

            %% generate a scanning individual call message
            Words = gen_call(?ALE_WORD_TYPE_TIS, Address, SelfAddress, CallType, AMDMessage),
            ok = send_words(Words), %% queue it up in the front end	
            %% Workaround for soundcard buffer latency, without it we may truncate our message
            %% by turning off the TX before the sound is fully played out.
            ok = send_gap(?SOUNDCARD_LATENCY),

            % spawn_notify_ale_event(ale_ind_call, EventData),
            NextTimeout = ?ALE_TRW * (length(Words) + 1) + ?SOUNDCARD_LATENCY + 5000,
            NewState = State#state{ link_state=unlinked, 
                                    call_dir=outbound, 
                                    other_address=Address,
                                    self_address=SelfAddress,
                                    reply_with_address=SelfAddress,
                                    wait_for_reply_time=NewWaitForReplyTime,
                                    timeout=NextTimeout, 
                                    % eot=false, 
                                    freq=Frequency,
                                    amd=AMDMessage,
                                    call_type=CallType,
                                    retries=Retries - 1},
            {next_state, call_wait_tx_complete, NewState}%%, NextTimeout}
        end;
idle({tx_complete}, State) ->
    %% ignore it, but make sure TX is off
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),        
    next_state_idle(State);
idle({amd, _Message, _Retries}, State) ->
    lager:error("can't send AMD when not in a call"),    
    next_state_idle(State);    
idle(timeout, State) ->
    lager:debug("Got timeout in idle state??"),
    next_state_idle(State).

send_sound_2g4g(Freq) ->
    {_,[H,_,M,_,S,_,Ms]} = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms(os:timestamp()))),
    Formatted = lists:flatten(["[",H,":",M,":",S,".",Ms,"]","[FRQ ",integer_to_list(Freq), "]","[ALE][SND][SENDING 2G/4G TWS SOUNDING]"]),

    spawn_notify_ale_event(ale_tx_sound, {data, list_to_binary(Formatted)}),
    
    %% generate a sounding
    ChannelSets = "HFNHFL",
    SelfAddress = radio_db:read_config(id),        
    Sound2G4GWords = gen_call(?ALE_WORD_TYPE_TWAS, "HFR", SelfAddress, non_scanning, ChannelSets),
    ok = send_words(Sound2G4GWords),    
    % ok = send_gap(?ALE_INTER_MESSAGE_GAP),
    % Words = gen_sound(),
    % ok = send_words(Words), %% queue it up in the front end
    %% Workaround for soundcard buffer latency, without it we may truncate our message
    %% by turning off the TX before the sound is fully played out.
    ok = send_gap(?SOUNDCARD_LATENCY),

    %% return the Freq and expected timeout time for this sounding (plus some slop time for the PA switching)
   	(?ALE_TRW * length(Sound2G4GWords)) + ?ALE_INTER_MESSAGE_GAP + ?ALE_TT + ?ALE_PA_SWITCH_TIME + ?ALE_PA_SWITCH_TIME +  ?SOUNDCARD_LATENCY + 5000.

send_sound_nmotd(Freq) ->
    {_,[H,_,M,_,S,_,Ms]} = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms(os:timestamp()))),
    Formatted = lists:flatten(["[",H,":",M,":",S,".",Ms,"]","[FRQ ",integer_to_list(Freq), "]","[ALE][SND][SENDING NMOTD]"]),

    spawn_notify_ale_event(ale_tx_sound, {data, list_to_binary(Formatted)}),
    
    %% generate a sounding
    AmdMsg = "12 TO 22 Oct 2018 HF INTEROPERABILITY EXERCISE HAM RADIO HFIE",
    SelfAddress = radio_db:read_config(id),        
    SoundNMOTDWords = gen_call(?ALE_WORD_TYPE_TWAS, "HFN", SelfAddress, non_scanning, AmdMsg),
    ok = send_words(SoundNMOTDWords),
    %% Workaround for soundcard buffer latency, without it we may truncate our message
    %% by turning off the TX before the sound is fully played out.
    ok = send_gap(?SOUNDCARD_LATENCY),

    %% return the Freq and expected timeout time for this sounding (plus some slop time for the PA switching)
   	(?ALE_TRW * length(SoundNMOTDWords)) + ?ALE_INTER_MESSAGE_GAP + ?ALE_TT + ?ALE_PA_SWITCH_TIME + ?ALE_PA_SWITCH_TIME +  ?SOUNDCARD_LATENCY + 5000.


send_sound(Freq) ->
    % EventData = {freq,Freq},
    % case whereis(backend_handler) of
    %     undefined -> lager:info("no control device is connected");
    %     _ ->
    {_,[H,_,M,_,S,_,Ms]} = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms(os:timestamp()))),
    Formatted = lists:flatten(["[",H,":",M,":",S,".",Ms,"]","[FRQ ",integer_to_list(Freq), "]","[ALE][SND][SENDING 2G/4G TWS SOUNDING]"]),
    %         Event = backend_handler:build_response([{event,ale_tx_sound},{data, list_to_binary(Formatted)}]),
    %         backend_handler ! {data, Event}
    % end,  
    spawn_notify_ale_event(ale_tx_sound, {data, list_to_binary(Formatted)}),
    
    %% generate a sounding
    %% XXX TODO: pull channel sets from database
    % ChannelSets = "HFNHFL",
    % SelfAddress = radio_db:read_config(id),        
    % Sound2G4GWords = gen_call(?ALE_WORD_TYPE_TWAS, "HFR", SelfAddress, non_scanning, ChannelSets),
    % ok = send_words(Sound2G4GWords),    
    % ok = send_gap(?ALE_INTER_MESSAGE_GAP),
    Words = gen_sound(),
    ok = send_words(Words), %% queue it up in the front end
    %% Workaround for soundcard buffer latency, without it we may truncate our message
    %% by turning off the TX before the sound is fully played out.
    ok = send_gap(?SOUNDCARD_LATENCY),

    %% return the Freq and expected timeout time for this sounding (plus some slop time for the PA switching)
   	% (?ALE_TRW * length(Words)) + (?ALE_TRW * length(Sound2G4GWords)) + ?ALE_INTER_MESSAGE_GAP + ?ALE_TT + ?ALE_PA_SWITCH_TIME + ?ALE_PA_SWITCH_TIME +  ?SOUNDCARD_LATENCY + 5000.
   	(?ALE_TRW * length(Words)) + ?ALE_INTER_MESSAGE_GAP + ?ALE_TT + ?ALE_PA_SWITCH_TIME + ?ALE_PA_SWITCH_TIME +  ?SOUNDCARD_LATENCY + 5000.

next_timeout(Timeout, _Period) when Timeout =< 10 ->
    %% If timeout already less than (or equal) 10 return it
    Timeout;
next_timeout(Timeout, Period) when Period >= Timeout ->
    %% -10ms to ensure timeout can occur (otherwise the PHA events keep it from timeout)
    %% we use 10 here since often that is that is the best granularity of the OS.
    Timeout - 10;
next_timeout(Timeout, Period) ->
    Timeout - Period.

call_wait_tx_complete({rx_word, Word}, State=#state{timeout=Timeout, message_state=MessageState}) ->
    % lager:warning("got rx_word ~8.16.0b while waiting for TX complete!", [Word]),
    NewMessageState = receive_msg(Word, MessageState),
    case {NewMessageState#msg_state.status, lists:flatten(NewMessageState#msg_state.conclusion)} of
        {_, []} ->
            % lager:debug("incomplete or fragment received during call_wait_tx_complete, ignoring..."),
            %% take no action
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState = State#state{message_state=NewMessageState, timeout=NextTimeout},
            {next_state, call_wait_tx_complete, NewState};%%, NextTimeout};
        {incomplete, _} ->
            %% take no action
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState = State#state{message_state=NewMessageState, timeout=NextTimeout},
            {next_state, call_wait_tx_complete, NewState};%%, NextTimeout};
        {complete, [_ConclusionType|FromAddr]} ->
            lager:debug("heard complete message"),
            From = string:strip(lists:flatten(FromAddr),right,$@),
            SelfAddressMatch = radio_db:read_self_address(From),                    
            case SelfAddressMatch of
                {error, not_found} ->
                    lager:warning("ALE message received from another station, abort sounding..."),
                    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off), % just in case!
                    %{ok, scan} = tuner_control(State#state.tuner_control, scan), % just in case
                    abort_tx(),    
                    spawn_tell_user_eot(),
                    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),
                    %% direcly jump to idle state
                    {next_state, idle, NextState} = next_state_idle(State),
                    NewState=NextState#state{sound_timer_ref=SndTimerRef, message_state=MessageState},                            
                    idle({rx_word, Word}, NewState); %% send this last word to the idle state to handle it
                {ok,{self_address,_MyAddress,own,_NetMember,_NetSlot,_Channels,_WaitForReplyTime}} ->
                    %% it's from us, don't report
                    lager:debug("call is from us..."),
                    NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                    NewState=State#state{timeout=NextTimeout, message_state=#msg_state{}},
                    {next_state, call_wait_tx_complete, NewState}%%, Timeout}
            end
    end;
		% end;
call_wait_tx_complete({tx_complete}, State=#state{wait_for_reply_time=WaitForReplyTime}) ->
    lager:debug("got tx_complete"),
    %% Time to turn off transmitter and switch back to RX
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),    
    NewMessageState = #msg_state{},
    NewState = State#state{message_state=NewMessageState, timeout=WaitForReplyTime},
    {next_state, call_wait_handshake_response, NewState, WaitForReplyTime};
call_wait_tx_complete({sound_all}, State=#state{timeout=Timeout}) ->
    lager:debug("got scanning sound event, rescheduling..."),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},
    %%% XXX using Timeout here, effectively resets the tx_complete timeout timer, is there a better way?
    {next_state, call_wait_tx_complete, NewState};%%, Timeout};    
call_wait_tx_complete(timeout, State) ->
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    %{ok, scan} = tuner_control(State#state.tuner_control, scan),
    abort_tx(),
    spawn_tell_user_eot(),
    lager:error("timeout occurred while waiting for tx_complete"),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},    
    next_state_idle(NewState).

compute_ber(LastBadVotes, LastWordCount) when LastWordCount > 0 ->
    round(?ALE_MAX_BER_VAL - (float(LastBadVotes) / float(LastWordCount)));
compute_ber(_LastBadVotes, _LastWordCount) ->
    0.0.

%%
%% States for sounding on all specified channels
%%

%% Continue to listen before transmit sounding state (maybe this state is unnecessary???)
%% For now we don't get fast waveform detections, just received words, otherwise timeout and go sound
sounding_lbt({current_freq,Freq}, State) ->
    lager:warning("received user freq change during LBT, abort sounding..."),
        {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    %{ok, scan} = tuner_control(State#state.tuner_control, scan),
    abort_tx(),
    spawn_tell_user_eot(),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},    
    {next_state, idle, NextState} = next_state_idle(NewState),
    idle({current_freq,Freq}, NextState);
sounding_lbt({rx_word, Word}, State=#state{timeout=Timeout, message_state=MessageState}) ->
    NewMessageState = receive_msg(Word, MessageState),
    Conclusion = lists:flatten(NewMessageState#msg_state.conclusion),
    
    case {NewMessageState#msg_state.status, Conclusion} of
        {_, []} ->
            lager:debug("incomplete or fragment recieved during LBT"),
            %% take no action
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState = State#state{message_state=NewMessageState, timeout=NextTimeout},
            {next_state, sounding_lbt, NewState, NextTimeout};
        {incomplete,_} ->
            %% take no action
            lager:debug("incomplete recieved during LBT"),
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState = State#state{message_state=NewMessageState, timeout=NextTimeout},
            {next_state, sounding_lbt, NewState, NextTimeout};
        {complete, [_ConclusionType|FromAddr]} ->
            From = string:strip(lists:flatten(FromAddr),right,$@),
            SelfAddressMatch = radio_db:read_self_address(From),                    
            case SelfAddressMatch of
                {error, not_found} ->
                    lager:warning("ALE message received from another station, abort sounding..."),
                    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off), % just in case!
                    %{ok, scan} = tuner_control(State#state.tuner_control, scan), % just in case
                    abort_tx(),    
                    spawn_tell_user_eot(),
                    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),
                    %% direcly jump to idle state
                    {next_state, idle, NextState} = next_state_idle(State),
                    NewState=NextState#state{sound_timer_ref=SndTimerRef, message_state=MessageState},    
                    idle({rx_word, Word}, NewState); %% send this last word to the idle state to handle it
                {ok,{self_address,MyAddress,own,_NetMember,_NetSlot,_Channels,WaitForReplyTime}} ->
                    %% it's from us, don't report
                    lager:debug("[SOUNDING_LBT] sounding is from us..."),
                    NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                    NewState=State#state{timeout=NextTimeout,  message_state=#msg_state{}},
                    {next_state, sounding_lbt, NewState, NextTimeout}
            end
		end;
sounding_lbt(timeout,  State=#state{sounding_channels=Channels, sound_freq=SndFreq}) ->
    lager:debug("nothing heard, sounding..."),
    %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
    {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),
    NextTimeout = send_sound(SndFreq),
    NewState = State#state{link_state=unlinked, call_dir=none, other_address=[], timeout=NextTimeout, sounding_channels=Channels},
    {next_state, sounding, NewState}.%%, NextTimeout}.

tell_user_eot() ->
    case whereis(backend_handler) of
        undefined -> lager:info("no control device is connected");
        _ ->
            EventMsg = backend_handler:build_response([{event,<<"tx_complete">>}]),
            backend_handler ! {data, EventMsg}
    end.

spawn_tell_user_eot() ->
    _Pid = spawn(ale, tell_user_eot,[]).

%%
%% Wait for radio and PA to tune while listening for traffic
%%
sounding_tune_wait_lbt(timeout, State=#state{sounding_channels=[]}) ->
    %% no channels left, done with sounding
    spawn_tell_user_eot(),
    lager:debug("emtpy channel list, done."),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),            
    NewState=State#state{sound_timer_ref=SndTimerRef},        
    next_state_idle(NewState);
sounding_tune_wait_lbt(timeout, State=#state{sounding_channels=[Chan|Channels]}) ->
    lager:debug("done waiting for tune now LBT..."),

    %% Need extra delay for Hardrock 50, so doing this here, FIXME !!!!
    _ChanFreq = pa_control_port:tune_pa(State#state.pa_control, Chan),
    NextTimeout = ?ALE_SOUND_LBT_TIMEOUT,
    NewState = State#state{timeout=NextTimeout, sounding_channels=Channels},
    {next_state, sounding_lbt, NewState, NextTimeout};
sounding_tune_wait_lbt({current_freq,Freq}, State) ->
    lager:warning("received user freq change during sounding_tune_wait_lbt, abort sounding..."),    
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off), % just in case!
    %{ok, scan} = tuner_control(State#state.tuner_control, scan), % just in case
    abort_tx(),
    spawn_tell_user_eot(),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),            
    NewState=State#state{sound_timer_ref=SndTimerRef},        
    {next_state, idle, NextState} = next_state_idle(NewState),
    idle({current_freq,Freq}, NextState);
sounding_tune_wait_lbt({rx_word, Word}, State=#state{timeout=Timeout, message_state=MessageState}) ->
    NewMessageState = receive_msg(Word, MessageState),
    Conclusion = lists:flatten(NewMessageState#msg_state.conclusion),
    
    case {NewMessageState#msg_state.status, Conclusion} of
        {_, []} ->
            lager:debug("incomplete or fragment recieved during sounding"),
            %% take no action
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState = State#state{message_state=NewMessageState, timeout=NextTimeout},
            {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};
        {incomplete,_} ->
            %% take no action
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState = State#state{message_state=NewMessageState, timeout=NextTimeout},
            {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};
        {complete, [_ConclusionType|FromAddr]} ->
            From = string:strip(lists:flatten(FromAddr),right,$@),
            SelfAddressMatch = radio_db:read_self_address(From),                    
            case SelfAddressMatch of
                {error, not_found} ->
                    lager:warning("ALE message received from another station, abort sounding..."),
                    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off), % just in case!
                    %{ok, scan} = tuner_control(State#state.tuner_control, scan), % just in case
                    abort_tx(),    
                    spawn_tell_user_eot(),
                    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),
                    %% direcly jump to idle state
                    {next_state, idle, NextState} = next_state_idle(State),
                    NewState=NextState#state{sound_timer_ref=SndTimerRef, message_state=MessageState},    
                    idle({rx_word, Word}, NewState); %% send this last word to the idle state to handle it
                {ok,{self_address,MyAddress,own,_NetMember,_NetSlot,_Channels,WaitForReplyTime}} ->
                    %% it's from us, don't report
                    lager:debug("[SOUNDING_TUNE_WAIT_LBT] sounding is from us..."),
                    NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                    NewState=State#state{timeout=NextTimeout,  message_state=#msg_state{}},
                    {next_state, sounding_tune_wait_lbt, NewState, NextTimeout}
            end
		end.

sounding({current_freq,Freq}, State) ->
    lager:warning("received user freq change during sounding, abort sounding..."),
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off), %% just in case
    %{ok, scan} = tuner_control(State#state.tuner_control, scan), %% just in case
    abort_tx(),
    spawn_tell_user_eot(),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),            
    NewState=State#state{sound_timer_ref=SndTimerRef},
    {next_state, idle, NextState} = next_state_idle(NewState),
    idle({current_freq,Freq}, NextState);
sounding({rx_word, Word}, State=#state{timeout=Timeout, message_state=MessageState}) ->
    NewMessageState = receive_msg(Word, MessageState),
    Conclusion = lists:flatten(NewMessageState#msg_state.conclusion),                
    case {NewMessageState#msg_state.status, Conclusion} of
        {_, []} ->
            % lager:debug("incomplete or fragment recieved during sounding"),
            %% take no action
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState = State#state{message_state=NewMessageState, timeout=NextTimeout},
            {next_state, sounding, NewState};%%, NextTimeout};
        {incomplete, _} ->
            lager:debug("incomplete recieved during sounding"),
            %% take no action
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState = State#state{message_state=NewMessageState, timeout=NextTimeout},
            {next_state, sounding, NewState};%%, NextTimeout};                    
        {complete, [_ConclusionType|FromAddr]} ->
            lager:debug("heard complete message"),
            From = string:strip(lists:flatten(FromAddr),right,$@),
            SelfAddressMatch = radio_db:read_self_address(From),                    
            case SelfAddressMatch of
                {error, not_found} ->
                    lager:warning("ALE message received from another station ~p, abort sounding...",[From]),
                    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off), % just in case!
                    %{ok, scan} = tuner_control(State#state.tuner_control, scan), % just in case
                    abort_tx(),    
                    spawn_tell_user_eot(),
                    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_RETRY_PERIOD),
                    %% direcly jump to idle state
                    {next_state, idle, NextState} = next_state_idle(State),
                    NewState=NextState#state{sound_timer_ref=SndTimerRef, message_state=MessageState},                            
                    idle({rx_word, Word}, NewState); %% send this last word to the idle state to handle it
                {ok,{self_address,MyAddress,own,_NetMember,_NetSlot,_Channels,WaitForReplyTime}} ->
                    %% it's from us, don't report
                    lager:debug("[SOUNDING] sounding is from us..."),
                    NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                    NewState=State#state{timeout=NextTimeout, message_state=#msg_state{}},
                    {next_state, sounding, NewState}%%, NextTimeout}
            end
    end;
sounding({tx_complete}, State=#state{sounding_channels=[]}) ->		
    lager:info("sounding complete..."),
    %% Time to turn off transmitter and switch back to RX
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    spawn_tell_user_eot(),

    %% re init the sounding timer for next time
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
    NewState = State#state{sound_timer_ref=SndTimerRef, sounding_channels=[]},
    next_state_idle(NewState);
sounding({tx_complete}, State=#state{sounding_channels=[Chan|Channels]}) ->
    %% Time to turn off transmitter and switch back to RX
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    ChanFreq = radio_control_port:tune_transmitter(State#state.transmit_control, Chan),
    ok = radio_control_port:transmitter_mode(State#state.transmit_control, Chan),
    lager:debug("got tx complete, tuning radio for ~p",[ChanFreq]),
    NextTimeout = ?ALE_PA_SWITCH_TIME,
    NewState = State#state{link_state=unlinked, call_dir=none, other_address=[], timeout=NextTimeout, sounding_channels=[Chan|Channels], sound_freq = ChanFreq},
    {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};    
sounding(timeout, State) ->
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    %{ok, scan} = tuner_control(State#state.tuner_control, scan),
    abort_tx(),

    %% turn on the receiver (only for use with external transmitters)
    % rx_enable(true),

    spawn_tell_user_eot(),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},      
    lager:error("timeout occurred while waiting for tx_complete"),
    next_state_idle(NewState).

%%
%% Wait for handshake response
%% 
call_wait_handshake_response({rx_word, Word}, State=#state{ link_state=LinkState, 
                                                            call_dir=CallDir, 
                                                            other_address=OtherAddress, 
                                                            self_address=MyAddress,
                                                            reply_with_address=ReplyWithAddress,
                                                            message_state=MessageState, 
                                                            timeout=Timeout}) ->
    %% process incoming message words
    NewMessageState = receive_msg(Word, MessageState),

    %% decide what to do 
    case NewMessageState#msg_state.status of 
        complete ->
            LastBadVotes = NewMessageState#msg_state.last_bad_votes,
            WordCount = NewMessageState#msg_state.word_count,
            Calling = NewMessageState#msg_state.calling,
            Message = NewMessageState#msg_state.message,
            Conclusion = NewMessageState#msg_state.conclusion,
            Conclusion_List = NewMessageState#msg_state.conclusion_list,
            Frequency = NewMessageState#msg_state.frequency,

            BestConclusion = find_longest_conclusion(Conclusion_List),
            Ber = compute_ber(LastBadVotes, WordCount),
            Sinad = NewMessageState#msg_state.sinad,

            case {CallDir, Calling, Message, BestConclusion} of
                {_, [to|ToAddr], Message, [tws|FromAddr]} ->
                    %% got link rejection message

                    %% decode any possible AMD messages
                    {ok, AMDMessageList} = amd_decode(Message, []),

                    %% handle other message types here

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,right,$@),
                    From = string:strip(FromAddr,right,$@), 

                    %% Send to user if they are connected
                    ok = spawn_amd_notify(From,AMDMessageList),

                    case {To, OtherAddress} of
                        { MyAddress, From } ->
                            lager:notice("got link rejection from ~p BER: ~p", [FromAddr, Ber]),
                            SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
                            NewState=State#state{sound_timer_ref=SndTimerRef},                             
                            next_state_idle(NewState);
                        _Others ->
                            lager:notice("heard termination message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                            NewMessageState = #msg_state{},
                            NewState = State#state{other_address=OtherAddress, message_state=NewMessageState, timeout=Timeout},
                            {next_state, call_wait_handshake_response, NewState, Timeout}							
                    end;
                {outbound, [to|ToAddr], Message, [tis|FromAddr]} ->
                    %% got link response message

                    %% decode any possible AMD messages
                    {ok, AMDMessageList} = amd_decode(Message, []),

                    %% handle other message types here

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,right,$@),
                    From = string:strip(FromAddr,right,$@), 

                    case {LinkState, To, From} of
                        { unlinked, MyAddress, OtherAddress } ->
                            lager:notice("[unlinked] got response from ~p BER: ~p", [FromAddr, Ber]),

                            %% turn off the receiver (only for use with external transmitters)
                            % rx_enable(false),
                            
                            %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
                            {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),                            
                            AckWords = gen_ack(OtherAddress, ReplyWithAddress),
                            ok = send_words(AckWords), %% queue it up in the front end					
                            %% Workaround for soundcard buffer latency, without it we may truncate our message
                            %% by turning off the TX before the sound is fully played out.
                            ok = send_gap(?SOUNDCARD_LATENCY),                            

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),

                            NextMessageState = #msg_state{},
                            NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            NewState = State#state{link_state=unlinked, other_address=OtherAddress, message_state=NextMessageState, timeout=NextStateTimeout},
                            {next_state, call_ack, NewState, NextStateTimeout};
                        { linked, MyAddress, OtherAddress } ->
                            lager:notice("[linked] got response from ~p BER: ~p", [FromAddr, Ber]),

                            %% turn off the receiver (only for use with external transmitters)
                            % rx_enable(false),
                            
                            %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
                            {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),                            
                            AckWords = gen_ack(OtherAddress,ReplyWithAddress),
                            ok = send_words(AckWords), %% queue it up in the front end									
                            %% Workaround for soundcard buffer latency, without it we may truncate our message
                            %% by turning off the TX before the sound is fully played out.
                            ok = send_gap(?SOUNDCARD_LATENCY),         

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),

                            NextMessageState = #msg_state{},
                            NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            NewState=State#state{link_state=linked, other_address=OtherAddress, message_state=NextMessageState, timeout=NextStateTimeout},
                            {next_state, call_ack, NewState, NextStateTimeout};	
                        _Others ->
                            lager:notice("heard response message; not for us: ~p BER: ~p", [{To, Message, From}, Ber]),
                            NextMessageState = #msg_state{},
                            NewState = State#state{other_address=OtherAddress, message_state=NextMessageState, timeout=Timeout},
                            {next_state, call_wait_handshake_response, NewState, Timeout}
                    end;	
                {inbound, [to|ToAddr], Message, [tis|FromAddr]} ->
                    %% got link ack message

                    %% decode any possible AMD messages
                    {ok, AMDMessageList} = amd_decode(Message, []),

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,right,$@),
                    From = string:strip(FromAddr,right,$@), 

                    case {LinkState, To, From} of
                        { unlinked, MyAddress, OtherAddress } ->
                            lager:notice("got acknowledge from ~p BER: ~p", [FromAddr, Ber]),
                            % TODO:  alert user and unmute speaker

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),
                            %% handle other message types here

                            lager:notice("ALE call handshake complete. ~p", [OtherAddress]),
                            spawn_notify_ale_event(ale_inbound_call_linked, {data,list_to_binary(OtherAddress)}),                            
                            NextMessageState = #msg_state{},
                            NewState=State#state{link_state=linked, other_address=OtherAddress, message_state=NextMessageState, timeout=?ALE_TWA},
                            {next_state, call_linked, NewState, ?ALE_TWA};
                        { linked, MyAddress, OtherAddress } ->
                            lager:notice("got acknowledge from ~p BER: ~p", [FromAddr, Ber]),
                            lager:notice("ALE message handshake complete. ~p", [OtherAddress]),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),
                            %% handle other message types here

                            NextMessageState = #msg_state{},
                            NewState=State#state{link_state=linked, other_address=OtherAddress, message_state=NextMessageState, timeout=?ALE_TWA},
                            {next_state, call_linked, NewState, ?ALE_TWA};							
                        _Others ->
                            lager:notice("heard response message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                            NextMessageState = #msg_state{},
                            NewState = State#state{other_address=OtherAddress, message_state=NextMessageState, timeout=Timeout},
                            {next_state, call_wait_handshake_response, NewState, Timeout}
                    end;									
                {_, [], [], [tws|FromAddr]} ->
                    %% got sounding

                    %% cleanup addresses / strip off the fill characters
                    From = string:strip(lists:flatten(FromAddr),right,$@),
                    spawn_store_lqa_and_report(Frequency, [], [tws|From], {Ber,Sinad}, []),
                    NextMessageState = #msg_state{},
                    NewState = State#state{other_address=OtherAddress, message_state=NextMessageState, timeout=Timeout},					
                    {next_state, call_wait_handshake_response, NewState, Timeout};					
                Others ->
                    lager:warning("call_wait_handshake_response: improper message sections: ~p",[Others]),
                    NextMessageState = #msg_state{},
                    NewState = State#state{other_address=OtherAddress, message_state=NextMessageState, timeout=Timeout},
                    {next_state, call_wait_handshake_response, NewState, Timeout}
            end;
        incomplete ->
            % NewMessageState = {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount},
            NewState = State#state{message_state=NewMessageState, timeout=Timeout},
            {next_state, call_wait_handshake_response, NewState, Timeout}
    end;
call_wait_handshake_response(timeout, State=#state{ link_state=LinkState, 
                                                    call_dir=CallDir, 
                                                    other_address=OtherAddress, 
                                                    self_address=MyAddress,
                                                    % reply_with_address=ReplyWithAddress,
                                                    % message_state=MessageState, 
                                                    % timeout=Timeout,
                                                    freq=Frequency,
                                                    amd=AMDMessage,
                                                    call_type=CallType,
                                                    retries=Retries}) ->
    case CallDir of 
        outbound ->
            RetriesLeft = Retries > 0,
            case {LinkState, RetriesLeft} of
                {unlinked, true}  ->
                    gen_fsm:send_event(ale, {call, OtherAddress, Frequency, CallType, AMDMessage, Retries}),
                    next_state_idle(State);
                {unlinked, false} ->
                    lager:warning("IMPLEMENT ME: call response timeout, alert user"),
                    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
                    NewState=State#state{sound_timer_ref=SndTimerRef},             
                    next_state_idle(NewState);
                {linked, true} ->
                    gen_fsm:send_event(ale, {call, OtherAddress, Frequency, CallType, AMDMessage, Retries}),
                    lager:warning("incomplete handshake"),
                    lager:debug("IMPLEMENT ME: send notification to HMI"),
                    NewState = State#state{timeout=?ALE_TWA},			
                    {next_state, call_linked, NewState, ?ALE_TWA};
                {linked, false} ->
                    lager:warning("incomplete handshake"),
                    lager:debug("IMPLEMENT ME: send notification to HMI"),
                    NewState = State#state{timeout=?ALE_TWA},			
                    {next_state, call_linked, NewState, ?ALE_TWA}             
                end;
        inbound ->
            case LinkState of
                unlinked ->
                    lager:warning("IMPLEMENT ME: call response timeout, alert user"),
                    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
                    NewState=State#state{sound_timer_ref=SndTimerRef},             
                    next_state_idle(NewState);
                linked ->
                    lager:warning("incomplete handshake"),
                    lager:debug("IMPLEMENT ME: send notification to HMI"),
                    NewState = State#state{timeout=?ALE_TWA},			
                    {next_state, call_linked, NewState, ?ALE_TWA}
            end   
    end.

%%
%% Wait for ACK to complete
%%
call_ack({rx_word, Word}, State=#state{timeout=Timeout}) ->
    % <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    % case DataLinkCtrl of
    %     ?ALE_DATALINK_EOT ->
    %         %% Time to turn off transmitter and switch back to RX
    %         {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    %         %{ok, scan} = tuner_control(State#state.tuner_control, scan),

    %         %% turn on the receiver (only for use with external transmitters)
    %         % rx_enable(true),
            
    %         NextTimeout = next_timeout(Timeout, ?ALE_TRW),
    %         NewState=State#state{timeout=NextTimeout},
    %         tx_complete(),
    %         {next_state, call_ack, NewState, NextTimeout};
    %     _Other ->
    lager:warning("got rx_word ~8.16.0b while waiting for TX complete!", [Word]),
    {next_state, call_ack, State, Timeout};
		% end;
call_ack({tx_complete}, State=#state{link_state=LinkState, other_address=OtherAddress}) ->
    %% Time to turn off transmitter and switch back to RX
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    case LinkState of
        unlinked ->
            % TODO: alert user and unmute speaker
            lager:notice("ALE call handshake complete. Linked with ~p", [OtherAddress]),
            spawn_notify_ale_event(ale_outbound_call_linked, {data,list_to_binary(OtherAddress)});            
        linked ->
            lager:notice("ALE msg handshake complete."),
            spawn_notify_ale_event(ale_msg_success, {data,list_to_binary(OtherAddress)})
    end,
    NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
    NewState=State#state{other_address=OtherAddress, message_state=NewMessageState, timeout=?ALE_TWA},
    {next_state, call_linked, NewState, ?ALE_TWA};
call_ack(timeout, State) ->
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    %{ok, scan} = tuner_control(State#state.tuner_control, scan),
    abort_tx(),

    %% turn on the receiver (only for use with external transmitters)
    % rx_enable(true),
    
    spawn_tell_user_eot(),
    lager:error("call_ack: datalink timeout: check modem!"),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},     
    next_state_idle(NewState).	

%%
%% Wait for transmitted response to complete
%%
call_wait_response_tx_complete({rx_word, Word}, State=#state{timeout=Timeout}) ->
    % <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    % case DataLinkCtrl of
    %     ?ALE_DATALINK_EOT ->
    %         %% Time to turn off transmitter and switch back to RX
    %         {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    %         %{ok, scan} = tuner_control(State#state.tuner_control, scan),

    %         %% turn on the receiver (only for use with external transmitters)
    %         % rx_enable(true),
            
    %         NextTimeout = next_timeout(Timeout, ?ALE_TRW),
    %         NewState=State#state{timeout=NextTimeout},
    %         tx_complete(),
    %         {next_state, call_wait_response_tx_complete, NewState};%%, NextTimeout};
        % _Other ->
    lager:warning("got rx_word ~8.16.0b while waiting for TX complete!", [Word]),
    {next_state, call_wait_response_tx_complete, State};%%, Timeout}
		% end;
call_wait_response_tx_complete({tx_complete}, State=#state{wait_for_reply_time=WaitForReplyTime}) ->
    %% Time to turn off transmitter and switch back to RX
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    %% wait for complete
    spawn_tell_user_eot(),
    NewMessageState = #msg_state{},
    NewState=State#state{message_state=NewMessageState, timeout=WaitForReplyTime},
    {next_state, call_wait_handshake_response, NewState, WaitForReplyTime};
call_wait_response_tx_complete(timeout, State) ->
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    %{ok, scan} = tuner_control(State#state.tuner_control, scan),
    abort_tx(),

    %% turn on the receiver (only for use with external transmitters)
    % rx_enable(true),
    
    spawn_tell_user_eot(),
    lager:error("call_wait_response_tx_complete: tx timeout! Check hardware!"),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},     
    next_state_idle(NewState).

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

%%
%% Little helper to join list of amd messages into a longer list with newlines
%%
join([], _) -> [];
join([List|Lists], Separator) ->
     lists:flatten([List | [[Separator,Next] || Next <- Lists]]).

spawn_amd_notify(_OtherAddress, []) ->
    ok;
spawn_amd_notify(OtherAddress, AMDMessageList) ->
    _Pid = spawn(ale, amd_notify, [OtherAddress, AMDMessageList]),
    ok.

amd_notify(_OtherAddress, []) ->
    ok;
amd_notify(OtherAddress, [Message|Rest]) ->
    lager:notice("AMD from ~p:~p to HMI if connected", [OtherAddress, Message]),
    case whereis(backend_handler) of
        undefined -> lager:info("backend_handler not registered");
        _ ->
            AMDBin = list_to_binary(Message),
            Msg = backend_handler:build_response([{event,ale_inbound_msg},{data,jsx:encode([{address, list_to_binary(OtherAddress)},{message, AMDBin}])}]),
            backend_handler ! {data, Msg}
    end,
    amd_notify(OtherAddress, Rest).


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

%%
%% Receive ALE message, one word at a time. Validate characters, word
%% ordering, collects message sections, and track message state.
%%
receive_msg(Word, MsgState) ->  %{Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount}) ->
    <<DataLinkCtrl:2,BadVotes:6,Type:3,C1:7,C2:7,C3:7>> = <<Word:32>>,
    <<DataLinkCtrl:2,Sinad:5,Frequency:25>> = <<Word:32>>,
    lager:debug("ALE TRACE(~8.16.0b) => DatalinkCtrl: ~p BadVotes: ~p Type: ~p ~c~c~c",[Word, DataLinkCtrl, BadVotes, Type, C1, C2, C3]),

    Message = MsgState#msg_state.message,
    Calling = MsgState#msg_state.calling,
    Conclusion = MsgState#msg_state.conclusion,

    %% FIXME: add case fpr ALE_DATALINK_EOT
    case DataLinkCtrl of 
        ?ALE_DATALINK_EVT ->
            % lager:debug("got event word. Ignoring for now..."),
            MsgState;
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
            WordBer = compute_ber(BadVotes,1),
            WordHist = alqa:histogram_pber(WordBer),
            NewPberHist = alqa:vecadd(MsgState#msg_state.pber_hist, WordHist,[]),
            lager:debug("NewPberHist=~p",[NewPberHist]),

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
                                        word_count=NewWordCount,
                                        pber_hist=NewPberHist};

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
                                        last_bad_votes=NewBadVotes, word_count=NewWordCount, pber_hist=NewPberHist};

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};					

                { _, _, ?ALE_WORD_TYPE_TIS } ->
                    %% if invalid chars ignore this word, no state change
                    {Valid, NewChars} = char_validate38([C1,C2,C3]),	
                    NextSection = case Valid of
                        ok -> conclusion;
                        error -> Section
                    end,                    
                    % lager:debug("got TIS word"),			
                    MsgState#msg_state{	status=incomplete, 
                                        section=NextSection, 
                                        conclusion=[tis,NewChars],
                                        conclusion_list=[lists:flatten(MsgState#msg_state.conclusion)|MsgState#msg_state.conclusion_list],
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount,pber_hist=NewPberHist};				    

                { _, _, ?ALE_WORD_TYPE_TWAS } ->
                    %% if invalid chars ignore this word, no state change
                    {Valid, NewChars} = char_validate38([C1,C2,C3]),	
                    NextSection = case Valid of
                        ok -> conclusion;
                        error -> Section
                    end,                    
                    % lager:debug("got TWAS word"),				
                    MsgState#msg_state{	status=incomplete, 
                                                      section=NextSection, 
                                                      conclusion=[tws,NewChars], 
                                                      conclusion_list=[lists:flatten(MsgState#msg_state.conclusion)|MsgState#msg_state.conclusion_list],
                                                      last_type=Type,
                                                      last_bad_votes=NewBadVotes, 
                                                      word_count=NewWordCount,pber_hist=NewPberHist};

                { calling, ?ALE_WORD_TYPE_TWAS, ?ALE_WORD_TYPE_CMD } ->
                    %%% Invalid sequence %%%
                    %% TODO: ignore this word, go IDLE?
                    lager:notice("improper type ~p received",[[?ALE_WORD_TYPE_TWAS, ?ALE_WORD_TYPE_CMD]]),
                    MsgState#msg_state{	status=incomplete, 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount,pber_hist=NewPberHist};						

                { calling, ?ALE_WORD_TYPE_TIS, ?ALE_WORD_TYPE_CMD } ->
                    %%% Invalid sequence %%%
                    %% TODO: ignore this word, go IDLE?
                    lager:notice("improper type ~p received",[[?ALE_WORD_TYPE_TIS, ?ALE_WORD_TYPE_CMD]]),
                    MsgState#msg_state{	status=incomplete, 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount,pber_hist=NewPberHist};						

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};				    

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};				    

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};					    

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};				    

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};				    

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};				    

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};				    			    

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
                                        word_count=NewWordCount,pber_hist=NewPberHist};					

                { conclusion, ?ALE_WORD_TYPE_TWAS, ?ALE_WORD_TYPE_DATA } ->
                    lager:debug("TWAS -> DATA"),
                    {_, NewChars} = char_validate38([C1,C2,C3]),					
                    %% if invalid, NewChars is []
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount,pber_hist=NewPberHist};		

                { conclusion, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_REP } ->
                    lager:debug("DATA -> REP"),
                    %% if invalid, NewChars is []
                    {_, NewChars} = char_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount,pber_hist=NewPberHist};						

                { conclusion, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_DATA } ->
                    lager:debug("REP -> DATA"),
                    %% if invalid, NewChars is []
                    {_, NewChars} = char_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount,pber_hist=NewPberHist};						
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
                                        word_count=NewWordCount,pber_hist=NewPberHist}				
            end
    end.

next_state_idle(State) ->
    NewMessageState = #msg_state{},
    NewState = State#state{link_state=unlinked, other_address=[], message_state=NewMessageState},
    {next_state, idle, NewState}.

%%
%% Call linked
%%
call_linked({call, _Address, _Type, _Message}, State) ->
    %% currently we only support one link at a time (could be a group or net call, but still only one)
    lager:error("already linked"),
    {next_state, call_linked, State, ?ALE_TWA};
call_linked({link_terminate, AMDMessage}, State=#state{other_address=OtherAddress,reply_with_address=ReplyWithAddress}) ->
    lager:notice("terminating link with ~p",[OtherAddress]),

    %% turn off the receiver (only for use with external transmitters)
    % rx_enable(false),
    
    %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
    {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),    
    TermWords = gen_terminate(OtherAddress,ReplyWithAddress,AMDMessage),
    ok = send_words(TermWords),
    %% Workaround for soundcard buffer latency, without it we may truncate our message
    %% by turning off the TX before the sound is fully played out.
    ok = send_gap(?SOUNDCARD_LATENCY),
    
    NextTimeout = length(TermWords) * (?ALE_TRW * 2),
    NextState = State#state{timeout=NextTimeout},
    {next_state, call_linked_wait_terminate, NextState, NextTimeout};
call_linked({amd, AMDMessage, Retries}, State=#state{other_address=OtherAddress, reply_with_address=ReplyWithAddress}) ->

    %% turn off the receiver (only for use with external transmitters)
    % rx_enable(false),

    %%{ok, tuned} = tuner_control(State#state.tuner_control, tuned),
    {ok, on} = radio_control_port:transmit_control(State#state.transmit_control, on),
    Words = gen_call(?ALE_WORD_TYPE_TIS, OtherAddress, ReplyWithAddress, non_scanning, AMDMessage),
    ok = send_words(Words), %% queue it up in the front end	
    %% Workaround for soundcard buffer latency, without it we may truncate our message
    %% by turning off the TX before the sound is fully played out.
    ok = send_gap(?SOUNDCARD_LATENCY),
    
    NextTimeout = ?ALE_TRW * (length(Words) + 1),
    NewState = State#state{link_state=linked, call_dir=outbound, timeout=NextTimeout, retries=Retries - 1},
    {next_state, call_wait_tx_complete, NewState};%%, NextTimeout};
call_linked({rx_word, Word}, State=#state{  other_address=OtherAddress, 
                                            self_address=MyAddress,
                                            reply_with_address=ReplyWithAddress,
                                            message_state=MessageState, 
                                            timeout=Timeout}) ->
        NewMessageState = receive_msg(Word, MessageState),

    case NewMessageState#msg_state.status of 
        complete ->
            %% got a complete message, validate it, then take action
            LastBadVotes = NewMessageState#msg_state.last_bad_votes,
            WordCount = NewMessageState#msg_state.word_count,
            Calling = NewMessageState#msg_state.calling,
            Message = NewMessageState#msg_state.message,
            Conclusion = NewMessageState#msg_state.conclusion,
            Conclusion_List = NewMessageState#msg_state.conclusion_list,
            BestConclusion = find_longest_conclusion(Conclusion_List),
            Ber = compute_ber(LastBadVotes, WordCount),
            Sinad = NewMessageState#msg_state.sinad,
            Frequency = NewMessageState#msg_state.frequency,

            %% cleanup addresses / strip off the fill characters
            % [ToSection|ToAddr] = Calling,
            % [FromSection|FromAddr] = BestConclusion, 
            
            case {Calling, Message, BestConclusion} of
                {[to|ToAddr], Message, [tws|FromAddr]} ->
                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,right,$@),
                    From = string:strip(FromAddr,right,$@), 

                    %% got link termination message

                    %% handle any possible AMD messages
                    {ok,AMDMessageList} = amd_decode(Message, []),

                    %% handle other message types here
                    IsForMe = lists:member(To, [MyAddress, "?@?"]),
                    IsFromLinkedStation = From == OtherAddress,
                    case {IsForMe, IsFromLinkedStation} of
                        { true, true } ->
                            %% Send to user if they are connected
                            ok = spawn_amd_notify(OtherAddress,AMDMessageList),

                            %% log / report
                            spawn_store_lqa_and_report(Frequency, To, [tws|From], {Ber,Sinad}, AMDMessageList),
                            lager:notice("got link termination from ~p BER: ~p", [FromAddr, Ber]),
                            spawn_notify_ale_event(ale_call_unlinked, {data,list_to_binary(OtherAddress)}),                            

                            SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
                            NewState=State#state{sound_timer_ref=SndTimerRef},     
                            next_state_idle(NewState);
                        _Others ->
                            lager:notice("heard termination message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                            %% log / report
                            spawn_store_lqa_and_report(Frequency, To, [tws|From], {Ber,Sinad}, AMDMessageList),
                            NewState = State#state{other_address=OtherAddress, message_state=NewMessageState, timeout=Timeout},
                            {next_state, call_linked, NewState, Timeout}            
                    end;
                {[to|ToAddr], Message, [tis|FromAddr]} ->

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,right,$@),
                    From = string:strip(FromAddr,right,$@), 

                    %%
                    %% FIXME: if this was a net call linkup, then we must always respond in the correct slot. One
                    %% solution might be to always use net_slot to decide when to reply, and for individual calls
                    %% this is just 0 (zero).
                    %%
                    IsForMe = lists:member(To, [MyAddress, "?@?"]),
                    IsFromLinkedStation = From == OtherAddress,
                    case {IsForMe, IsFromLinkedStation} of
                        { true, true } ->
                            %% got message while linked
                            lager:notice("got message from ~p BER: ~p", [FromAddr, Ber]),

                            %% decode any possible AMD messages
                            {ok, AMDMessageList} = amd_decode(Message, []),

                            %% Send to user if they are connected
                            ok = spawn_amd_notify(From,AMDMessageList),

                            %% log / report
                            spawn_store_lqa_and_report(Frequency, To, [tis|From], {Ber,Sinad}, AMDMessageList),

                            %% handle other message types here

                            %% send ack
                            AckWords = gen_ack(From, ReplyWithAddress),
                            ok = send_words(AckWords), %% queue it up in the front end					
                            %% Workaround for soundcard buffer latency, without it we may truncate our message
                            %% by turning off the TX before the sound is fully played out.
                            ok = send_gap(?SOUNDCARD_LATENCY),
                            
                            NextMessageState = #msg_state{},
                            NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            NewState = State#state{link_state=linked, call_dir=inbound, other_address=From, message_state=NextMessageState, timeout=NextStateTimeout},
                            {next_state, call_wait_response_tx_complete, NewState};%%, NextStateTimeout};
                        _Others ->
                            lager:notice("heard message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                            NextMessageState = #msg_state{},
                            NewState = State#state{message_state=NextMessageState, timeout=?ALE_TWA},
                            {next_state, call_linked, NewState, ?ALE_TWA}
                    end;	

                {[], [], [tws|FromAddr]} ->
                    %%
                    %% got sounding
                    %%

                    %% cleanup addresses / strip off the fill characters
                    spawn_store_lqa_and_report(Frequency, [], [tws|FromAddr], {Ber,Sinad}, []),
                    NextMessageState = #msg_state{},
                    NewState = State#state{other_address=OtherAddress, message_state=NextMessageState, timeout=Timeout},					
                    {next_state, call_linked, NewState, Timeout};					
                Others ->
                    %% error, got nothing
                    lager:warning("call_linked: improper message sections: ~p",[Others]),
                    NextMessageState = #msg_state{},
                    NewState = State#state{other_address=OtherAddress, message_state=NextMessageState, timeout=Timeout},
                    {next_state, call_linked, NewState, Timeout}
            end;
        incomplete ->
            NewState = State#state{other_address=OtherAddress, message_state=NewMessageState, timeout=Timeout},
            {next_state, call_linked, NewState, Timeout}
    end;
call_linked({current_freq,Freq}, State) ->
    %% currently we only support one link at a time (could be a group or net call, but still only one)
    lager:error("user changed changed freq during link -> ~p", [Freq]),
    {next_state, call_linked, State, ?ALE_TWA};    
call_linked(timeout, State) ->
    lager:notice("link idle timeout with ~p", [State#state.other_address]),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},     
    next_state_idle(NewState).

call_linked_wait_terminate({rx_word, Word}, State=#state{timeout=Timeout}) ->
    % <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
%    case DataLinkCtrl of
%         ?ALE_DATALINK_EOT ->
%             %% Time to turn off transmitter and switch back to RX
%             {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
%             %{ok, scan} = tuner_control(State#state.tuner_control, scan),
%             NextTimeout = next_timeout(Timeout, ?ALE_TRW),
%             NewState=State#state{timeout=NextTimeout},
%             tx_complete(),
%             {next_state, call_linked_wait_terminate, NewState, NextTimeout};
%         _Other ->
    lager:debug("got rx_word ~8.16.0b while waiting for TX complete!", [Word]),
    {next_state, call_linked_wait_terminate, State};
		% end;
call_linked_wait_terminate({tx_complete}, State) ->
    %% Time to turn off transmitter and switch back to RX
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    lager:notice("link terminated"),
    spawn_tell_user_eot(),    
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef}, 
    next_state_idle(NewState);
call_linked_wait_terminate(timeout, State) ->
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),
    %{ok, scan} = tuner_control(State#state.tuner_control, scan),
    abort_tx(),

    %% turn on the receiver (only for use with external transmitters)
    % rx_enable(true),
    
    spawn_tell_user_eot(),
    lager:error("datalink timeout during link termination"),
    SndTimerRef = start_sounding_timer(State#state.transmit_control, ?ALE_SOUNDING_PERIOD),
    NewState=State#state{sound_timer_ref=SndTimerRef},     
    next_state_idle(NewState).

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
%% Function to determine HFLink reporting smeter string. As per Alan Barrow KM4BA alan@pinztrek.com
%% BER icon:
%% Smeter icons will be included if the smeter keywork is appended to the
%% frame and in the exact engineering format. They specific keywords should
%% be sent based on the following BER levels:
%%          " smeter4" if ( $line =~ /BER 27|BER 28|BER 29/ );
%%          " smeter3" if ( $line =~ /BER 24|BER 25|BER 26/ );
%%          " smeter2" if ( $line =~ /BER 21|BER 22|BER 23/ );
%%          " smeter1" if ( $line =~ /BER 0\d|BER 1\d|BER 20/ );
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

spawn_send_hflink_report(ReportString) ->
    _Pid = spawn(ale, send_hflink_report, [ReportString]).

spawn_store_lqa_and_report(Freq, To, Conclusion, {Ber, Sinad}, Message) ->
    _Pid = spawn(ale, store_lqa_and_report, [Freq, To, Conclusion, {Ber, Sinad}, Message]).

store_lqa_and_report(Freq, To, Conclusion, {Ber, Sinad}, Message) ->
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

    %% simple way to weed out invalid or partial callsigns
    %% RegExp = "\\d?[a-zA-Z]{1,2}\\d{1,4}[a-zA-Z]{1,4}",
    %% case re:run(CleanId, RegExp) of

    case length(Id) >= 3 of
        true ->
            {Megasec,Sec,Micro} = os:timestamp(),
            Timestamp = Megasec * 1000000 + Sec,

            %% store it in the contact database
            Contact = 	#contact{ id 			= list_to_binary(Id),
                                  time 		    = Timestamp,
                                  channel 	    = Channel,
                                  frequency 	= Freq,
                                  ber 		    = Ber,
                                  sinad 		= Sinad,
                                  name 		    = Name,
                                  coordinates   = Coordinates,
                                  power 		= Power,
                                  radio 		= Radio,
                                  controller 	= Controller,
                                  antenna 	    = Antenna
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
            ReportHeader = io_lib:format("nick=H3F3N3 ~s&shout=",[MyId]),
            Smeter = get_smeter_string(Ber),
            ReportFooter = io_lib:format(" BER+~.2.0w+SN+~.2.0w+~s&email=linker&send=&Submit=send", [Ber, Sinad, Smeter]),
            Report = iolist_to_binary(ReportHeader ++ http_uri:encode(Formatted) ++ Message ++ ReportFooter),
            lager:info("HFLink Report: ~p~n", [Report]),
            ReportEnabled = radio_db:read_config(hflink_reporting),
            case ReportEnabled of
                true ->
                    spawn_send_hflink_report(Report);
                false ->
                    lager:info("HFLINK Reporting disabled")
            end,

            %% if control device is connected, send it the contact and log event
            % case whereis(backend_handler) of
                % undefined -> lager:debug("no control device is connected");
                % _ ->
                    %% format and send this contact to control device
            ContactEJSON = contact:to_json(Contact),
                    %% build contact message
            % ContactMsg = backend_handler:build_response([{event,ale_new_contact}, {data, jsx:encode(ContactEJSON)}]),
            spawn_notify_ale_event(ale_new_contact, {data,jsx:encode(ContactEJSON)}),
                    %% send it
            % backend_handler ! {data, ContactMsg},
                    %% build log even message
            spawn_notify_ale_event(ale_rx_sound, {data,list_to_binary(Formatted)});
            % Event = backend_handler:build_response([{event,ale_rx_sound},{data, list_to_binary(Formatted)}]),
                    %% send it
            % backend_handler ! {data, Event};
            % end;
        false ->
            lager:warning("invalid or partial callsign, ignored")
    end.

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
gen_scanning_sound(ScanTimeMs, true, Address) ->
    {ok, Words} = build_ale_address($@, ?ALE_WORD_TYPE_TIS, Address),
    % Words = list_to_binary(Words),
    ScanTimeWords = gen_scanning_sound_rep(Words, length(Words), ScanTimeMs, []),
    lists:flatten(gen_scanning_sound_rep(Words, length(Words) * ?ALE_TA, 4 * length(Words) * ?ALE_TA, ScanTimeWords));
gen_scanning_sound(ScanTimeMs, false, Address) ->
    {ok, Words} = build_ale_address($@, ?ALE_WORD_TYPE_TWAS, Address),
    % Words = list_to_binary(Words),
    ScanTimeWords = gen_scanning_sound_rep(Words, length(Words) * ?ALE_TA, ScanTimeMs, []),
    lists:flatten(gen_scanning_sound_rep(Words, length(Words) * ?ALE_TA, 4 * length(Words) * ?ALE_TA, ScanTimeWords)).

gen_scanning_sound_rep(Words, AddrLenMs, ScanTimeMs, SoundWords) when ScanTimeMs > AddrLenMs ->
    gen_scanning_sound_rep(Words, AddrLenMs, ScanTimeMs - AddrLenMs, [Words|SoundWords]);
gen_scanning_sound_rep(_Words, _AddrLenMs, _ScanTimeMs, SoundWords) ->	
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
    % ChannelCount = radio_db:channel_count(),
    % ScanTime = ?ALE_TRW * ChannelCount + ?ALE_TRW * 2,
    RespReq = false,
    %% if this isn't set we crash
    MyAddress = radio_db:read_config(id),
    gen_scanning_sound(?ALE_SCAN_PREAMBLE_TIME, RespReq, MyAddress).

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

gen_call(Terminator, OtherAddress, SelfAddress, non_scanning, AMDMessage) ->
    ScanTime = 0,
    gen_scanning_call(Terminator, ScanTime, OtherAddress, SelfAddress, AMDMessage);
gen_call(Terminator, OtherAddress, SelfAddress, scanning, AMDMessage) ->
    % ChannelCount = radio_db:channel_count(),
    % ScanTime = ?ALE_TRW * ChannelCount + ?ALE_TRW * 2,
    gen_scanning_call(Terminator, ?ALE_SCAN_PREAMBLE_TIME, OtherAddress, SelfAddress, AMDMessage).

gen_ack(OtherAddress, ReplyWithAddress) ->
    % MyAddress = radio_db:read_config(id),
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, OtherAddress),
    LeadingCall = [ToWords, ToWords],
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TIS, ReplyWithAddress),
    CompleteCall = [LeadingCall, FromCall],
    lists:flatten(CompleteCall).	

gen_terminate(OtherAddress, SelfAddress, []) ->
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, OtherAddress),
    LeadingCall = [ToWords, ToWords],
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TWAS, SelfAddress),
    CompleteCall = [LeadingCall, FromCall],
    lists:flatten(CompleteCall);	
gen_terminate(OtherAddress, SelfAddress, AMDMessage) ->
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, OtherAddress),
    LeadingCall = [ToWords, ToWords],
    %% Validate then add in the AMD message section
    {ok, MessageWords} = build_ale_message($ , ?ALE_WORD_TYPE_CMD, AMDMessage),
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TWAS, SelfAddress),
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
