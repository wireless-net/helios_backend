%%
%% ALE datalink layer functionality
%%

-module(ale).

-behaviour(gen_fsm).

-include("modem.hrl").

-export([rx/1
        , start_link/0
        , scanning_sound/3
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
        , tx_complete/0
        , ctrl_disconnect/0
        , gen_sound/0
        , gen_terminate/2
        , gen_ack/1
        , gen_call/3
        , list_validate38/1
        , list_validate64/1
        , amd_notify/2
        , send_hflink_report/1
        , find_longest_conclusion/2
        , find_longest_conclusion/1
        , conv/2
        , test_send_words/1
        ]).

-export([rx_sound_complete/3]).

-export([init/1
        , handle_event/3
        , handle_sync_event/4
        , handle_info/3
        , terminate/3
        , code_change/4
        , idle/2
        , tx_sounding/2
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

                                                % -export([rx_start/0, rx_stop/0]).

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
-define(ALE_DATALINK_SNR	,	1).				%% SNR marker
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
-define(ALE_SOUNDING_PERIOD	,	30*60*1000).	%% try sounding every thirty minutes
-define(ALE_SOUNDING_RETRY_PERIOD, 5*60*1000). 	%% if abort, retry after 5 minutes of no activity

-record(msg_state, {
          status 			= incomplete,
          section 		= idle, 
          calling 		= [],
          message 		= [],
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
          freq 			= 0, 
          bad_votes 		= 0, 
          word_count 		= 0,
          call_address	= [],
          last_type		= none,
          message_state	= #msg_state{},
          call_dir		= outbound,
          link_state		= unlinked,
          timeout 		= ?ALE_SOUNDING_PERIOD,
          sounding_channels = [],
          sound_freq		= none
         }).

%%%===================================================================
%%% API
%%%===================================================================

                                                % Load new ALE wo`d that was just received by frontend
rx(Word) ->
    gen_fsm:send_event(ale, {rx_word, Word}).

                                                % Store current FNCTRL settings
fnctrl(Word) ->
    gen_fsm:send_event(ale, {fnctrl, Word}).

                                                % Update current frequency
current_freq(Word) ->
    gen_fsm:send_event(ale, {current_freq, Word}).

                                                % Sounding
sound() ->
    gen_fsm:send_event(ale, {sound}).

scanning_sound() ->
    gen_fsm:send_event(ale, {scanning_sound}).

                                                % individual call
call(Address) -> 
    gen_fsm:send_event(ale, {call, string:to_upper(Address), non_scanning,[]}).

                                                % individual scanning call
scanning_call(Address) ->
    gen_fsm:send_event(ale, {call, string:to_upper(Address), scanning,[]}).

                                                % individual call with AMD message
call(Address, AMDMessage) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH -> 
    gen_fsm:send_event(ale, {call, string:to_upper(Address), non_scanning, string:to_upper(AMDMessage)});
call(_Address, _AMDMessage) ->
    lager:error("AMD message must be less than ~p", [?ALE_MAX_AMD_LENGTH]),
    error.	

                                                % AMD message
amd(AMDMessage) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH -> 
    gen_fsm:send_event(ale, {amd, string:to_upper(AMDMessage)});
amd(_AMDMessage) ->
    lager:error("AMD message must be less than ~p", [?ALE_MAX_AMD_LENGTH]),
    error.

                                                % individual scanning call with AMD message
scanning_call(Address, AMDMessage) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH ->
    gen_fsm:send_event(ale, {call, string:to_upper(Address), scanning, string:to_upper(AMDMessage)});
scanning_call(_Address, _AMDMessage) ->
    lager:error("AMD message must be less than ~p", [?ALE_MAX_AMD_LENGTH]),
    error.	

                                                % link termination
link_terminate() ->
    gen_fsm:send_event(ale, {link_terminate,[]}).

                                                % link termination with AMD message
link_terminate(AMDMessage) when length(AMDMessage) < ?ALE_MAX_AMD_LENGTH ->
    gen_fsm:send_event(ale, {link_terminate, string:to_upper(AMDMessage)});
link_terminate(_AMDMessage) ->
    lager:error("AMD message must be less than ~p", [?ALE_MAX_AMD_LENGTH]),
    error.	

                                                % Tell the datalink that ALE tx completed
tx_complete() ->
    gen_fsm:send_event(ale, {tx_complete}).

                                                % Control device disconnected
ctrl_disconnect() ->
    gen_fsm:send_all_state_event(ale, {ctrl_disconnect}).

%% FOR DEBUGGING ONLY
                                                % rx_stop() ->
                                                % 	frontend_port:fnctrl(<<0,0,0,16#F0:8>>).
                                                % rx_start() ->
                                                % 	frontend_port:fnctrl(<<1,0,0,16#F0:8>>).

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
    %% FIXME: get these from the DB??
                                                % Rx = 1, %% turn on the RX by default
                                                % Tx = 0, %% off, but we don't control this anyway
                                                % RxMode=1,
                                                % TxMode=1,
                                                % TxSpec=1,
                                                % RxSpec=1,
                                                % FnctrlWord = <<0:2,TxSpec:1,TxMode:1,Tx:1,RxSpec:1,RxMode:1,Rx:1, 0:8, 0:8, 16#F0:8>>,
                                                % ok = frontend_port:fnctrl(FnctrlWord), 
                                                % TxGainWord = modem_db:read_config(ale_tx_gain),
                                                % ok = frontend_port:set_txgain(TxGainWord),    
    {ok, idle, #state{}, ?ALE_SOUNDING_PERIOD}.

%% ------------------------------------------------------------------
%% gen_fsm Function Definitions
%% ------------------------------------------------------------------
idle({link_terminate,_}, State) ->
    lager:error("not currently linked"),
    next_state_idle(State);	
idle({current_freq_set,Freq}, State) ->
    lager:debug("setting current Freq=~p", [Freq]),
    {atomic, ok} = modem_db:write_config(current_freq, Freq),
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
idle({rx_word, Word}, State=#state{call_address=[], message_state=MessageState, timeout=Timeout}) ->

    NewMessageState = receive_msg(Word, MessageState),

                                                % lager:info("Timeout=~p NextTimeout=~p",[Timeout, NextTimeout]),
    case NewMessageState#msg_state.status of 
        complete ->
                                                % got a complete message, validate it, then take action
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

            case {Calling, Message, BestConclusion} of
                {[to|ToAddr], Message, [tis|FromAddr]} ->

                    %%
                    %% got link request message
                    %%

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = modem_db:read_config(id),

                    case {To, From} of
                        { MyAddress, From } ->
                            lager:notice("got link request from ~p BER: ~p", [FromAddr, Ber]),

                            %%
                            %% handle any possible AMD messages
                            %%
                            ok = amd_notify(Message, Ber),

                            %%
                            %% handle other message types here
                            %%

                                                % send ack
                            AckWords = gen_ack(From),
                            ok = send_words(AckWords), %% queue it up in the front end					
                                                % wait for complete
                                                % alert user and unmute speaker
                                                % InitMessageState = #msg_state{},%{incomplete, idle, [], [], [], none, 0, 0},
                            NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            NewState = State#state{call_dir=inbound, call_address=From, message_state=#msg_state{}, timeout=NextStateTimeout},
                            {next_state, call_wait_response_tx_complete, NewState, NextStateTimeout};
                        _Others ->
                            lager:notice("heard link request message; not for us: ~p BER: ~p", [{Calling, Message, Conclusion}, Ber]),
                                                % InitMessageState = {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount},
                                                % InitMessageState = #msg_state{},%InitMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                            NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=Timeout},
                            {next_state, idle, NewState, Timeout}
                    end;				
                {[to|ToAddr], [], [tws|FromAddr]} ->
                    %%
                    %% got terminate or reject message while idle, treat at sounding
                    %%
                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(lists:flatten(FromAddr),both,$@),
                    lager:notice("heard termination from -- logging as sound TO: ~p FROM: ~p BER: ~p", [To, From, Ber]),
                                                % Freq = modem_db:read_config(current_freq),
                    rx_sound_complete(Frequency, [tws|From], {Ber,Sinad}),
                                                % InitMessageState = #msg_state{},%InitMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                    NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=Timeout},
                    {next_state, idle, NewState, Timeout};					
                {[], [], [MType|FromAddr]} ->
                    %%
                    %% got sounding with intact conclusion
                    %%

                    %% cleanup addresses / strip off the fill characters
                    From = string:strip(lists:flatten(FromAddr),both,$@),
                    rx_sound_complete(Frequency, [MType|From], {Ber,Sinad}),
                    NewState = State#state{call_address=[], message_state=#msg_state{}, timeout=Timeout},
                    {next_state, idle, NewState, Timeout};
                Others ->
                    lager:warning("idle: improper message sections: ~p",[Others]),
                    next_state_idle(State)
            end;
        incomplete ->
                                                % NewMessageState = {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount},
            NewState = State#state{message_state=NewMessageState, timeout=Timeout},
            {next_state, idle, NewState, Timeout}
    end;
idle({fnctrl, Word}, State) ->
    NewState=State#state{fnctrl=Word}, % replace exiting record for FNCTRL
    next_state_idle(NewState);
idle({sound}, State) ->
    %% TODO: need a way to detect if activity on channel: probably if activity detect message received within a time window, don't transmit. Can store a timestamp in state.
    Freq = modem_db:read_config(current_freq),
    _NextTimeout = send_sound(Freq),
    {next_state, tx_sounding, State};
idle({scanning_sound},  State) ->
    Channels = modem_db:find_auto_channels(),
    [Chan1|_] = Channels,
    %% tune the radio and PA
    ChanFreq = tune_radio(Chan1),
    NextTimeout = ?ALE_PA_SWITCH_TIME,
    NewState = State#state{link_state=unlinked, call_dir=none, call_address=[], timeout=NextTimeout, sounding_channels=Channels, sound_freq = ChanFreq},
    {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};   	
idle({call, Address, CallType, AMDMessage}, State) ->
    lager:debug("individual call request"),
    case whereis(backend_handler) of
        undefined -> lager:info("backend_handler not registered");
        _ ->
            Freq = modem_db:read_config(current_freq),	
            {_,[H,_,M,_,S,_,Ms]} = lager_util:format_time(lager_util:maybe_utc(lager_util:localtime_ms(os:timestamp()))),
            Formatted = lists:flatten(["[",H,":",M,":",S,".",Ms,"]","[FRQ ",integer_to_list(Freq), "]","[ALE][TO][",Address,"]"]),
            Event = backend_handler:build_response([{event,ale_ind_call},{data, list_to_binary(Formatted)}]),
            backend_handler ! {data, Event}
    end,

    %% get from db config
                                                % {atomic,[{config, ale_tx_gain, TxGainWord}]} = modem_db:read_config(ale_tx_gain),
                                                % lager:debug("TxGainWord=~p",[TxGainWord]),
                                                % ok = frontend_port:set_txgain(TxGainWord),

    %% generate a scanning individual call message
    Words = gen_call(Address, CallType, AMDMessage),
    ok = send_words(Words), %% queue it up in the front end	
    NextTimeout = ?ALE_TRW * (length(Words) + 1),
    NewState = State#state{link_state=unlinked, call_dir=outbound, call_address=Address, timeout=NextTimeout},
    {next_state, call_wait_tx_complete, NewState, NextTimeout};
idle({tx_complete}, State) ->
    %% ignore it, not an ale transmission
    NewState = State#state{timeout=?ALE_SOUNDING_PERIOD},
    {next_state, idle, NewState, ?ALE_SOUNDING_PERIOD};
idle(timeout, State) ->
    lager:debug("FIXME: NOT time to sound..."),
    NewState = State#state{timeout=?ALE_SOUNDING_PERIOD},
    {next_state, idle, NewState, ?ALE_SOUNDING_PERIOD}.
                                                % ale:scanning_sound(),
                                                % NewState = State#state{timeout=?ALE_SOUNDING_PERIOD},
                                                % {next_state, idle, NewState, ?ALE_SOUNDING_PERIOD}.

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
    Words = gen_sound(),
    ok = send_words(Words), %% queue it up in the front end
    %% return the Freq and expected timeout time for this sounding (plus some slop time for the PA switching)
   	?ALE_TRW * length(Words) + ?ALE_TT + ?ALE_PA_SWITCH_TIME + ?ALE_PA_SWITCH_TIME.

next_timeout(Timeout, _Period) when Timeout =< 10 ->
    %% if timeout already less than (or equal) 10 return it
    Timeout;
next_timeout(Timeout, Period) when Period >= Timeout ->
                                                % -10ms to ensure timeout can occur (otherwise the PHA events keep it from timeout)
                                                % we use 10 here since often that is that is the best granularity of the OS.
    Timeout - 10;
next_timeout(Timeout, Period) ->
    Timeout - Period.

call_wait_tx_complete({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                                                % lager:info("call_wait_tx_complete: NextTimeout=~p",[NextTimeout]),
            NewState=State#state{timeout=NextTimeout},
            {next_state, call_wait_tx_complete, NewState, NextTimeout};
        _Other ->
            lager:warning("got rx_word while waiting for TX complete!"),
            {next_state, call_wait_tx_complete, State, Timeout}
		end;
call_wait_tx_complete({tx_complete}, State) ->
    lager:debug("got tx_complete"),
    NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
    NewState = State#state{message_state=NewMessageState, timeout=?ALE_TWRT},
    {next_state, call_wait_handshake_response, NewState, ?ALE_TWRT};
call_wait_tx_complete(timeout, State) ->
    lager:error("timeout occurred while waiting for tx_complete"),
    next_state_idle(State).

compute_ber(LastBadVotes, LastWordCount) when LastWordCount > 0 ->
    round(?ALE_MAX_BER_VAL - (float(LastBadVotes) / float(LastWordCount)));
compute_ber(_LastBadVotes, _LastWordCount) ->
    0.0.

%%
%% States for sounding on all specified channels
%%
tune_radio(Chan) ->
    case whereis(backend_handler) of
        undefined -> lager:info("no control device is connected");
        _ ->
            JSON = jsx:encode(channel:to_json(Chan)),
            Event = backend_handler:build_response([{event,<<"channel_update">>}, {channel,JSON}]),
            backend_handler ! {data, Event}
    end,
    ChanFreq = Chan#channel.frequency,
    {ok, _Ret2} = radio_control_port:set_freq(ChanFreq),
    ChanFreq.

tune_pa(Chan) ->
    ChanFreq = Chan#channel.frequency,
    {ok, _Ret2} = pa_control_port:set_freq(ChanFreq),
    ChanFreq.	

%% Continue to listen before transmit sounding state (maybe this state is unnecessary???)
%% For now we don't get fast waveform detections, just received words, otherwise timeout and go sound
sounding_lbt({current_freq,Freq}, State) ->
    lager:warning("received user freq change during LBT, abort sounding..."),
    {next_state, idle, NewState, _} = next_state_idle(State),
    idle({current_freq,Freq}, NewState);
sounding_lbt({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState=State#state{timeout=NextTimeout},
            {next_state, sounding_lbt, NewState, NextTimeout};
        _Other ->
            lager:warning("received word during LBT, abort sounding..."),
                                                % direcly jump to idle state
            {next_state, idle, NewState, _} = next_state_idle(State),
            idle({rx_word, Word}, NewState)
    end;
sounding_lbt(timeout,  State=#state{sounding_channels=Channels, sound_freq=SndFreq}) ->
    lager:debug("nothing heard, sounding..."),
    NextTimeout = send_sound(SndFreq),
    NewState = State#state{link_state=unlinked, call_dir=none, call_address=[], timeout=NextTimeout, sounding_channels=Channels},
    {next_state, sounding, NewState, NextTimeout}.

%%
%% Wait for radio and PA to tune while listening for traffic
%%
sounding_tune_wait_lbt({current_freq,Freq}, State) ->
    lager:warning("received user freq change during sounding_tune_wait_lbt, abort sounding..."),
    {next_state, idle, NewState, _} = next_state_idle(State),
    idle({current_freq,Freq}, NewState);
sounding_tune_wait_lbt({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState=State#state{timeout=NextTimeout},
            {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};
        _Other ->
            lager:warning("received, abort sounding_tune_wait_lbt..."),
                                                % direcly jump to idle state
            {next_state, idle, NewState, _} = next_state_idle(State),
            idle({rx_word, Word}, NewState)
		end;
sounding_tune_wait_lbt(timeout, State=#state{sounding_channels=[]}) ->
    lager:debug("final retune of PA"),
    Freq = modem_db:read_config(current_freq),
    {ok, _Ret2} = pa_control_port:set_freq(Freq),	
    next_state_idle(State);
sounding_tune_wait_lbt(timeout, State=#state{sounding_channels=[Chan|Channels]}) ->
    lager:debug("done waiting for tune now LBT..."),
    _ChanFreq = tune_pa(Chan),
    NextTimeout = ?ALE_SOUND_LBT_TIMEOUT,
    NewState = State#state{timeout=NextTimeout, sounding_channels=Channels},
    {next_state, sounding_lbt, NewState, NextTimeout}.

sounding({current_freq,Freq}, State) ->
    lager:warning("received user freq change during sounding, abort sounding..."),
    {next_state, idle, NewState, _} = next_state_idle(State),
    idle({current_freq,Freq}, NewState);
sounding({rx_word, Word}, State=#state{timeout=Timeout}) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
            NewState=State#state{timeout=NextTimeout},
            {next_state, sounding, NewState, NextTimeout};
        _Other ->
            lager:warning("received, abort sounding..."),
                                                % direcly jump to idle state
            {next_state, idle, NewState, _} = next_state_idle(State),
            idle({rx_word, Word}, NewState)
		end;
sounding({tx_complete}, State=#state{sounding_channels=[]}) ->		
    lager:debug("sounding complete..."),
    Freq = modem_db:read_config(current_freq),
    MatchList = modem_db:find_channel(Freq),
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
    {ok, _Ret2} = radio_control_port:set_freq(Freq),
    NextTimeout = ?ALE_PA_SWITCH_TIME,
    NewState = State#state{timeout=NextTimeout, sounding_channels=[]},
    {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};
sounding({tx_complete}, State=#state{sounding_channels=[Chan|Channels]}) ->
    lager:debug("got tx complete, tuning radio"),
    ChanFreq = tune_radio(Chan),
    NextTimeout = ?ALE_PA_SWITCH_TIME,
    NewState = State#state{link_state=unlinked, call_dir=none, call_address=[], timeout=NextTimeout, sounding_channels=[Chan|Channels], sound_freq = ChanFreq},
    {next_state, sounding_tune_wait_lbt, NewState, NextTimeout};    
sounding(timeout, State) ->
    lager:error("timeout occurred while waiting for tx_complete"),
    next_state_idle(State).

%%
%% Wait for handshake response
%% 
call_wait_handshake_response({rx_word, Word}, State=#state{link_state=LinkState, call_dir=CallDir, call_address=CallAddress, message_state=MessageState, timeout=Timeout}) ->

    %% process incoming message words
    {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount, {Sinad, Frequency}} = 
        receive_msg(Word, MessageState),

                                                % lager:info("call_wait_handshake_response NextTimeout=~p",[NextTimeout]),

    %% decide what to do 
    case Status of 
        complete ->
                                                % got a complete message, validate it, then take action
            Ber = compute_ber(LastBadVotes, WordCount),
            case {CallDir, Calling, Message, Conclusion} of
                {_, [to|ToAddr], Message, [tws|FromAddr]} ->
                    %%
                    %% got link rejection message
                    %%

                    %%
                    %% handle any possible AMD messages
                    %%
                    ok = amd_notify(Message, Ber),

                    %%
                    %% handle other message types here
                    %%

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = modem_db:read_config(id),

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
                    %%
                    %% got link response message
                    %%

                    %%
                    %% handle any possible AMD messages
                    %%
                    ok = amd_notify(Message, Ber),

                    %%
                    %% handle other message types here
                    %%

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = modem_db:read_config(id),

                    case {LinkState, To, From} of
                        { unlinked, MyAddress, CallAddress } ->
                            lager:notice("[unlinked] got response from ~p BER: ~p", [FromAddr, Ber]),
                            AckWords = gen_ack(CallAddress),
                            ok = send_words(AckWords), %% queue it up in the front end					
                            NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
                            NextStateTimeout = ?ALE_TRW * (length(AckWords) + 1),
                            NewState = State#state{link_state=unlinked, call_address=CallAddress, message_state=NewMessageState, timeout=NextStateTimeout},
                            {next_state, call_ack, NewState, NextStateTimeout};
                        { linked, MyAddress, CallAddress } ->
                            lager:notice("[linked] got response from ~p BER: ~p", [FromAddr, Ber]),
                            AckWords = gen_ack(CallAddress),
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
                    %%
                    %% got link ack message
                    %%

                    %%
                    %% handle any possible AMD messages
                    %%
                    ok = amd_notify(Message, Ber),

                    %%
                    %% handle other message types here
                    %%

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = modem_db:read_config(id),

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
                    %%
                    %% got sounding
                    %%

                    %% cleanup addresses / strip off the fill characters
                    From = string:strip(lists:flatten(FromAddr),both,$@),
                    Freq = modem_db:read_config(current_freq),
                    rx_sound_complete(Freq, [tws|From], {Ber,Sinad}),
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
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                                                % lager:info("call_ack: NextTimeout=~p",[NextTimeout]),
            NewState=State#state{timeout=NextTimeout},
            {next_state, call_ack, NewState, NextTimeout};
        _Other ->
            lager:warning("got rx_word while waiting for TX complete!"),
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
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                                                % lager:info("call_wait_response_tx_complete: NextTimeout=~p",[NextTimeout]),
            NewState=State#state{timeout=NextTimeout},
            {next_state, call_wait_response_tx_complete, NewState, NextTimeout};
        _Other ->
            lager:warning("got rx_word while waiting for TX complete!"),
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

amd_notify([], _Ber) ->
    ok;
amd_notify([[cmd_amd|Message]|Rest], Ber) ->
    lager:notice("AMD: ~ts BER: ~p",[Message, Ber]),
    lager:warning("IMPLEMENT ME: send AMD event to HMI if connected"),
    amd_notify(Rest, Ber);
amd_notify([_OtherType|Rest], Ber) ->
    amd_notify(Rest, Ber).

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
    lager:info("ALE WORD: ~8.16.0b~n", [Word]),

    Message = MsgState#msg_state.message,
    Calling = MsgState#msg_state.calling,
    Conclusion = MsgState#msg_state.conclusion,

    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            %% word phase tick
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
            case {MsgState#msg_state.section, MsgState#msg_state.last_type, Type} of
                { idle, _, ?ALE_WORD_TYPE_TO } ->
                    {_, NewChars} = list_validate38([C1,C2,C3]),	
                    MsgState#msg_state{	status=incomplete, 
                                        section=calling, 
                                        calling=[to,NewChars], 
                                        message=[], 
                                        conclusion=[],
                                        last_type=Type, 
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};

                { calling, _, ?ALE_WORD_TYPE_TO } ->
                    {_, NewChars} = list_validate38([C1,C2,C3]),	
                    MsgState#msg_state{	status=incomplete, 
                                        section=calling, 
                                        calling=[to,NewChars], 
                                        message=[], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, word_count=NewWordCount};

                { calling, ?ALE_WORD_TYPE_TO, ?ALE_WORD_TYPE_DATA } ->
                    {_, NewChars} = list_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=calling, 
                                        calling=[Calling|NewChars], 
                                        message=[], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};

                { calling, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_REP } ->
                    {_, NewChars} = list_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=calling, 
                                        calling=[Calling|NewChars], 
                                        message=[], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};

                { calling, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_DATA } ->
                    {_, NewChars} = list_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=calling, 
                                        calling=[Calling|NewChars], 
                                        message=[], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};					

                { _, _, ?ALE_WORD_TYPE_TIS } ->
                    {_, NewChars} = list_validate38([C1,C2,C3]),	
                    lager:debug("got TIS word"),			
                    %% if we already have a conclusion address, check if the first three match and if the old is longer keep the old, else keep the new
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[tis,NewChars],
                                        conclusion_list=[lists:flatten(MsgState#msg_state.conclusion)|MsgState#msg_state.conclusion_list],
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { _, _, ?ALE_WORD_TYPE_TWAS } ->
                    {_, NewChars} = list_validate38([C1,C2,C3]),	
                    lager:debug("got TWAS word"),				
                    NewMsgState = MsgState#msg_state{	status=incomplete, 
                                                      section=conclusion, 
                                                      conclusion=[tws,NewChars], 
                                                      conclusion_list=[lists:flatten(MsgState#msg_state.conclusion)|MsgState#msg_state.conclusion_list],
                                                      last_type=Type,
                                                      last_bad_votes=NewBadVotes, 
                                                      word_count=NewWordCount},
                    NewMsgState;

                { calling, ?ALE_WORD_TYPE_TWAS, ?ALE_WORD_TYPE_CMD } ->
%%% Invalid sequence %%%
                    lager:notice("improper type ~p received",[[?ALE_WORD_TYPE_TWAS, ?ALE_WORD_TYPE_CMD]]),
                    MsgState#msg_state{	status=incomplete, 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};						

                { calling, ?ALE_WORD_TYPE_TIS, ?ALE_WORD_TYPE_CMD } ->
%%% Invalid sequence %%%
                    lager:notice("improper type ~p received",[[?ALE_WORD_TYPE_TIS, ?ALE_WORD_TYPE_CMD]]),
                    MsgState#msg_state{	status=incomplete, 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};						

                { calling, _, ?ALE_WORD_TYPE_CMD } ->
                    MessageType = get_msg_type(C1),
                    {_, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
%%% Start of first CMD, put into a list of lists
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=[[MessageType|NewChars]], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, _, ?ALE_WORD_TYPE_CMD } ->

                    MessageType = get_msg_type(C1),
                    {_, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    %% another command in the same message section, just prepend it to list of lists
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=[lists:flatten([MessageType|NewChars])|Message], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, ?ALE_WORD_TYPE_CMD, ?ALE_WORD_TYPE_DATA } ->

                    MessageType = get_msg_type(C1),
                    {_, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=[lists:flatten([CurList|NewChars])|PrevList], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};					    

                { message, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_REP } ->

                    MessageType = get_msg_type(C1),
                    {_, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=[lists:flatten([CurList|NewChars])|PrevList], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_DATA } ->

                    MessageType = get_msg_type(C1),
                    {_, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=[lists:flatten([CurList|NewChars])|PrevList], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_DATA } ->
                    %% invalid, but above PHA handling code will have already substituted SUB chars
                    MessageType = get_msg_type(C1),
                    {_, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=[lists:flatten([CurList|NewChars])|PrevList], 
                                        conclusion=[], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};				    

                { message, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_REP } ->
                    %% invalid, but above PHA handling code will have already substituted SUB chars
                    MessageType = get_msg_type(C1),
                    {_, NewChars} = case MessageType of
                                        error -> {error,[]};
                                        cmd_amd -> list_validate64([C1,C2,C3]);
                                        unsupported -> {error,[]}
                                    end,
                    [CurList|PrevList] = Message,
                    MsgState#msg_state{	status=incomplete, 
                                        section=message, 
                                        message=[lists:flatten([CurList|NewChars])|PrevList], 
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
                    {_, NewChars} = list_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};					
                                                % D,Rx],Dx,R,D,R
                                                % this case is caught above
                                                % { conclusion, _, ?ALE_WORD_TYPE_TWAS } ->
                                                % 	{_, NewChars} = list_validate38([C1,C2,C3]),					
                                                %     {incomplete, conclusion, Calling, Message, [tws,NewChars], Type, NewBadVotes, NewWordCount,{?ALE_SINAD_UNKNOWN,0}};

                { conclusion, ?ALE_WORD_TYPE_TWAS, ?ALE_WORD_TYPE_DATA } ->
                    lager:debug("TWAS -> DATA"),
                    {_, NewChars} = list_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};		

                { conclusion, ?ALE_WORD_TYPE_DATA, ?ALE_WORD_TYPE_REP } ->
                    lager:debug("DATA -> REP"),
                    {_, NewChars} = list_validate38([C1,C2,C3]),					
                    MsgState#msg_state{	status=incomplete, 
                                        section=conclusion, 
                                        conclusion=[Conclusion|NewChars], 
                                        last_type=Type,
                                        last_bad_votes=NewBadVotes, 
                                        word_count=NewWordCount};						

                { conclusion, ?ALE_WORD_TYPE_REP, ?ALE_WORD_TYPE_DATA } ->
                    lager:debug("REP -> DATA"),
                    {_, NewChars} = list_validate38([C1,C2,C3]),					
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
    NewMessageState = #msg_state{},%NewMessageState = {incomplete, idle, [], [], [], none, 0, 0},
    NewState = State#state{link_state=unlinked, call_address=[], message_state=NewMessageState, timeout=?ALE_SOUNDING_PERIOD},
    {next_state, idle, NewState, ?ALE_SOUNDING_PERIOD}.

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
    Words = gen_call(CallAddress, non_scanning, AMDMessage),
    ok = send_words(Words), %% queue it up in the front end	
    NextTimeout = ?ALE_TRW * (length(Words) + 1),
    NewState = State#state{link_state=linked, call_dir=outbound, call_address=CallAddress, timeout=NextTimeout},
    {next_state, call_wait_tx_complete, NewState, NextTimeout};
call_linked({rx_word, Word}, State=#state{call_address=CallAddress, message_state=MessageState, timeout=Timeout}) ->
    {Status, Section, Calling, Message, Conclusion, LastType, LastBadVotes, WordCount,{Sinad,Frequency}} = 
        receive_msg(Word, MessageState),

                                                % lager:info("call_linked NextTimeout=~p",[NextTimeout]),

    case Status of 
        complete ->
                                                % got a complete message, validate it, then take action
            Ber = compute_ber(LastBadVotes, WordCount),
            case {Calling, Message, Conclusion} of
                {[to|ToAddr], Message, [tws|FromAddr]} ->

                    %%
                    %% got link termination message
                    %%

                    %%
                    %% handle any possible AMD messages
                    %%
                    ok = amd_notify(Message, Ber),

                    %%
                    %% handle other message types here
                    %%

                    %% cleanup addresses / strip off the fill characters
                    To = string:strip(ToAddr,both,$@),
                    From = string:strip(FromAddr,both,$@), 
                    MyAddress = modem_db:read_config(id),

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
                    MyAddress = modem_db:read_config(id),

                    case {To, From} of
                        { MyAddress, From } ->
                            %%
                            %% got message while linked
                            %%						
                            lager:notice("got message from ~p BER: ~p", [FromAddr, Ber]),

                            %%
                            %% handle any possible AMD messages
                            %%
                            ok = amd_notify(Message, Ber),

                            %%
                            %% handle other message types here
                            %%

                                                % send ack
                            AckWords = gen_ack(From),
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
                                                % Freq = modem_db:read_config(Frequency),
                    rx_sound_complete(Frequency, [tws|From], {Ber,Sinad}),
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
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
            NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                                                % lager:info("call_linked_wait_terminate: NextTimeout=~p",[NextTimeout]),
            NewState=State#state{timeout=NextTimeout},
            {next_state, call_linked_wait_terminate, NewState, NextTimeout};
        _Other ->
            lager:warning("got rx_word while waiting for TX complete!"),
            {next_state, call_linked_wait_terminate, State, Timeout}
		end;
call_linked_wait_terminate({tx_complete}, State) ->
    lager:notice("link terminated"),
    next_state_idle(State);
call_linked_wait_terminate(timeout, State) ->
    lager:error("datalink timeout during link termination"),
    next_state_idle(State).

tx_sounding({rx_word, Word}, State) ->
    <<DataLinkCtrl:2,_BadVotes:6,_Type:3,_C1:7,_C2:7,_C3:7>> = <<Word:32>>,
    case DataLinkCtrl of 
        ?ALE_DATALINK_PHA ->
                                                % NextTimeout = next_timeout(Timeout, ?ALE_TRW),
                                                % NewState=State#state{timeout=NextTimeout},
            {next_state, tx_sounding, State};
        _Other ->
            lager:warning("got rx_word while waiting for TX complete!"),
            {next_state, tx_sounding, State}
		end;
tx_sounding({tx_complete}, State) ->
    next_state_idle(State).

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

rx_sound_complete(Freq, Conclusion, {Ber, Sinad}) ->
    %% TODO: compute LQA and store in DB?
    %% Filter Id to make sure it is valid??
    [Type|Id] = Conclusion,
    TypeString = string:to_upper(atom_to_list(Type)),
    lager:info("heard contact: ~p:~p BER: ~p SINAD: ~p Frequency: ~p",[Type,Id,Ber,Sinad,Freq]),

    MatchList = modem_db:find_channel(Freq),
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
            {atomic, _} = modem_db:write_contact(Contact),
            lager:debug("wrote sounding to db"),

            %% format log message
            {{_Year, _Month, _Day},{H,M,S}} = calendar:now_to_universal_time({Megasec,Sec,Micro}),
            Formatted = io_lib:format("[~.2.0w:~.2.0w:~.2.0w][FRQ ~p][SND][~s][~s][AL0]", [H,M,S,Freq,TypeString,Id]),
            lager:notice("~s", [Formatted]),

            %%
            %% "nick=K6DRS&shout=%5B20%3A23%3A35%5D%5BFRQ+18106000%5D%5BSND%5D%5BTWS%5D%5BK6DRS%5D%5BAL0%5D+BER+24+SN+03+smeter3&email=linker&send=&Submit=send"
            %%
            %% POST to: http://hflink.net/log/postit.php
            %% check the DB to determine if HFLink reporting is enabled

            %% get myID from database
            MyId = modem_db:read_config(id),
            ReportHeader = io_lib:format("nick=H2F2N2 ~s&shout=",[MyId]),
            Smeter = get_smeter_string(Ber),
            ReportFooter = io_lib:format("BER+~.2.0w+SN+~.2.0w+~s&email=linker&send=&Submit=send", [Ber, Sinad, Smeter]),
            Report = iolist_to_binary(ReportHeader ++ http_uri:encode(Formatted) ++ ReportFooter),
            lager:info("HFLink Report: ~p~n", [Report]),
            ReportEnabled = modem_db:read_config(hflink_reporting),
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

list_validate38(Chars) ->
    case re:run(Chars, "^[0-9A-Za-z@]+$") of
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
                                                % do normal stuff, then call with REP
    {NewAddress, NewWord} = build_ale_word(FillChar, ?ALE_WORD_TYPE_DATA, Address, <<>>, 3),
    build_ale_words(FillChar, ?ALE_WORD_TYPE_REP, NewAddress, [NewWord|Words]);	
build_ale_words(FillChar, ?ALE_WORD_TYPE_REP, Address, Words) ->
                                                % do normal stuff, then call with DATA	
    {NewAddress, NewWord} = build_ale_word(FillChar, ?ALE_WORD_TYPE_REP, Address, <<>>, 3),
    build_ale_words(FillChar, ?ALE_WORD_TYPE_DATA, NewAddress, [NewWord|Words]);	
build_ale_words(FillChar, Type, Address, []) ->
    %% first entry point, all others all REP or DATA
    {NewAddress, NewWord} = build_ale_word(FillChar, Type, Address, <<>>, 3),
    build_ale_words(FillChar, ?ALE_WORD_TYPE_DATA, NewAddress, [NewWord]).

%% Entry point for building a list of ALE Address words from a string of up to
%% 15 characters. 
build_ale_address(FillChar, Type, Address) when length(Address) =< ?ALE_MAX_ADDRESS_LEN ->
    {ok, ValidChars } = list_validate38(Address), %% enforce basic ASCII 38 set for ALE
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
    scanning_sound_rep(Words, length(Words), ScanTimeMs, []);
scanning_sound(ScanTimeMs, false, Address) ->
    {ok, Words} = build_ale_address($@, ?ALE_WORD_TYPE_TWAS, Address),
    ScanTimeWords = scanning_sound_rep(Words, length(Words) * ?ALE_TA, ScanTimeMs, []),
    lists:flatten(scanning_sound_rep(Words, length(Words) * ?ALE_TA, 4 * length(Words) * ?ALE_TA, ScanTimeWords)).

scanning_sound_rep(Words, AddrLenMs, ScanTimeMs, SoundWords) when ScanTimeMs > AddrLenMs ->
    scanning_sound_rep(Words, AddrLenMs, ScanTimeMs - AddrLenMs, [Words | SoundWords]);
scanning_sound_rep(_Words, _AddrLenMs, _ScanTimeMs, SoundWords) ->	
    SoundWords.

send_words([]) ->
    ok;
send_words([W|Words]) ->
                                                % ok = frontend_port:txdata(<<W:32/unsigned-little-integer>>),
    lager:warning("not sending words: IMPLEMENT!"),
    send_words(Words).

gen_sound() ->
    %% get this from the DB / config data
%%% this should be Trw*num_channels + 2*Trw
    ChannelCount = modem_db:channel_count(),
    ScanTime = ?ALE_TRW * ChannelCount + ?ALE_TRW * 2,
    RespReq = false, 
    %% if this isn't set we crash
    MyAddress = modem_db:read_config(id),
    scanning_sound(ScanTime, RespReq, MyAddress).

gen_scanning_call_rep(Words, AddrLenMs, ScanTimeMs, CallWords) when ScanTimeMs > AddrLenMs ->
    gen_scanning_call_rep(Words, AddrLenMs, ScanTimeMs - AddrLenMs, [Words | CallWords]);
gen_scanning_call_rep(_Words, _AddrLenMs, _ScanTimeMs, CallWords) ->	
    CallWords.

%% generate scanning call with optional AMD message
gen_scanning_call(ScanTimeMs, Address, MyAddress, []) ->
    %% 1, replicated 1-word TO words
    {ok, ScanToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, lists:sublist(Address,3)),
    ScanTimeCall = gen_scanning_call_rep(ScanToWords, length(ScanToWords) * ?ALE_TA, ScanTimeMs, []),

    %% 2, leading call TO words X2
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, Address),
    LeadingCall = [ToWords, ToWords], %% 2X

    %% 3, from call TIS words
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TIS, MyAddress),

    CompleteCall = [ScanTimeCall, LeadingCall, FromCall],
    lists:flatten(CompleteCall);
gen_scanning_call(ScanTimeMs, Address, MyAddress, AMDMessage) ->
    %% 1, replicated 1-word TO words
    {ok, ScanToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, lists:sublist(Address,3)),
    ScanTimeCall = gen_scanning_call_rep(ScanToWords, length(ScanToWords) * ?ALE_TA, ScanTimeMs, []),

    %% 2, leading call TO words X2
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, Address),
    LeadingCall = [ToWords, ToWords], %% 2X

    %% 3. Validate then add in the AMD message section
    {ok, MessageWords} = build_ale_message($ , ?ALE_WORD_TYPE_CMD, AMDMessage),	

    %% 4, from call TIS words
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TIS, MyAddress),

    CompleteCall = [ScanTimeCall, LeadingCall, MessageWords, FromCall],
    lists:flatten(CompleteCall).

gen_call(Address, non_scanning, AMDMessage) ->
    ScanTime = 0,
    MyAddress = modem_db:read_config(id),
    gen_scanning_call(ScanTime, Address, MyAddress, AMDMessage);
gen_call(Address, scanning, AMDMessage) ->
    %% get this from the DB / config data
%%% this should be Trw*num_channels + 2*Trw
    ChannelCount = modem_db:channel_count(),
    ScanTime = ?ALE_TRW * ChannelCount + ?ALE_TRW * 2,
    MyAddress = modem_db:read_config(id),
    gen_scanning_call(ScanTime, Address, MyAddress, AMDMessage).

gen_ack(Address) ->
    MyAddress = modem_db:read_config(id),
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, Address),
    LeadingCall = [ToWords, ToWords],
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TIS, MyAddress),
    CompleteCall = [LeadingCall, FromCall],
    lists:flatten(CompleteCall).	

gen_terminate(Address, []) ->
    MyAddress = modem_db:read_config(id),
    {ok, ToWords} = build_ale_address($@, ?ALE_WORD_TYPE_TO, Address),
    LeadingCall = [ToWords, ToWords],
    {ok, FromCall} = build_ale_address($@, ?ALE_WORD_TYPE_TWAS, MyAddress),
    CompleteCall = [LeadingCall, FromCall],
    lists:flatten(CompleteCall);	
gen_terminate(Address, AMDMessage) ->
    MyAddress = modem_db:read_config(id),
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
