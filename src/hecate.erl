%%
%% HECATE HFLink sidechannel SELCALL (CCIR-493) support 
%%

-module(hecate).
-behaviour(gen_fsm).

-export([ generate_dot_pattern/2
        , encode_selcall/3
        , send_gap/2
        , send_words/2
        , abort_tx/0
        , tx_complete/0
        , handle_event/3
        , handle_sync_event/4
        , send_selective_revertive/1
        , handle_info/3
        , terminate/3
        , code_change/4
        , start_link/0
        , selcall/4
        , init/1
        , idle/2
        , call_wait_tx_complete/2
        , call_wait_revertive_response/2
        , call/5
        , test/5
        , page/6
        , rx/1
        , rx_revertive/1
        , store_lqa_and_report/5
        , notify_hecate_event/2
        , send_hflink_report/1
        ]).



-include("radio.hrl").

-define(SERVER, ?MODULE).

-record(msg_state, {
          status 			        = incomplete,
        %   section 		        = idle, 
          category            = routine,
          to                  = {},
          from                = {},
          arq                 = true,
          message 		        = [],
          type 		            = none,
          %%word_count 		      = 0, 
          sinad 			        = 0,
          subchan             = 0,
          frequency 		      = 0
         }).

-record(state, {
          freq 			          = 0, 
          word_count 		      = 0,
          other_address	      = [], %% address of other station during call/linkup
          self_address        = [], %% self address called by other station during call/linkup
          reply_with_address  = [], %% address to reply with during call/linkup
          wait_for_reply_time = 0,
          last_type		        = none,
          message_state	      = #msg_state{},
          call_dir		        = outbound,
          %link_state		      = unlinked,
          subchan             = a,
          timeout 		        = 0,
          transmit_control    = none,
          pa_control          = none,
          retries             = 0,
          amd                 = [],
          call_type           = non_scanning
         }).

-define(BAD_WORD, 16#80000000).
-define(SEL, 120).
-define(TST, 123).
-define(ARQ, 117).
-define(RTN, 100).
-define(PAG, 116).

-define(PREAMBLE_SHORT, 2000).                  % default short (non-scanning) preamble length
-define(SYMBOL_LENGTH_MS, 10).                  % length of a symbol in ms
-define(SELCALL_TWRT, 5000).                    % time to wait for selective call revertive


%% Handle new SELCALL word that was just received by frontend
rx(Msg) ->
    gen_fsm:send_event(hecate, {rx_msg, Msg}).

rx_revertive(<<Frequency:32/unsigned-little-integer>>) ->
    gen_fsm:send_event(hecate, {rx_revertive, Frequency}).

selcall(Freq, SubChan, ToAddr, Retries) ->
    gen_fsm:send_event(hecate, {call, Freq, SubChan, ToAddr, Retries}).

%% Tell the datalink that HECATE tx completed 
tx_complete() ->
    gen_fsm:send_event(hecate, {tx_complete}).

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
    lager:info("CCIR_493_4 Datalink starting..."),

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

    %% just in case we're restarting after a crash
    {ok, off} = radio_control_port:transmit_control(TransmitControlType, off),
    
    %% turn on the receiver (only for use with external transmitters)
    %% rx_enable(true),

    %% abort_tx(),
    % spawn_tell_user_eot(),

    %% OK go idle
    {ok, idle, #state{  transmit_control=TransmitControlType, 
                        pa_control=PaControlType}}.

next_state_idle(State) ->
    NewMessageState = #msg_state{},
    NewState = State#state{other_address=[], message_state=NewMessageState},
    {next_state, idle, NewState}.

decode_subchan(0) ->
    a;
decode_subchan(1) ->
    b;
decode_subchan(2) ->
    c;
decode_subchan(_) ->
    lager:error("invalid subchannel specified, using subchan=a"),
    a.


%% helper function to select between default or programmed TWRT timeout
select_wait_for_reply_time(default) ->
    ?SELCALL_TWRT;
select_wait_for_reply_time(WaitForReplyTime) ->
    WaitForReplyTime.


%% ------------------------------------------------------------------
%% gen_fsm Function Definitions
%% ------------------------------------------------------------------
idle({rx_revertive, Frequency}, State) ->
    lager:debug("detected revertive while idle on ~p",[Frequency]),
    next_state_idle(State);
idle({tx_complete}, State) ->
    %% ignore it, but make sure TX is off
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),        
    next_state_idle(State);
idle({rx_msg, Msg}, State=#state{other_address=[], transmit_control=TxCtrlType}) ->
    NewMessageState = receive_msg(Msg),

    case NewMessageState#msg_state.status of 
        complete ->
            %% got a complete message, validate it, then take action
            Type = NewMessageState#msg_state.type,
            Category = NewMessageState#msg_state.category,
            Arq = NewMessageState#msg_state.arq,
            SubChan = NewMessageState#msg_state.subchan,
            ToAddr = NewMessageState#msg_state.to,
            FromAddr = NewMessageState#msg_state.from,
            Message = NewMessageState#msg_state.message,
            %Sinad = NewMessageState#msg_state.sinad,
            Frequency = NewMessageState#msg_state.frequency,

            %% dummy values for now
            Ber = 30,
            Sinad = 30,

            lager:info("SelCall message received: Frequency: ~p, SubChan: ~p Type: ~p, To: ~p, From: ~p, Message: ~p, Category: ~p, ARQ: ~p"
                      ,[Frequency, SubChan, Type, ToAddr, FromAddr, Message, Category, Arq]),

            ToSelfAddressMatch = radio_db:read_self_address(ToAddr),
            FromSelfAddressMatch = radio_db:read_self_address(FromAddr),

            %% log/report	
            spawn_store_lqa_and_report(Frequency, ToAddr, FromAddr, {Ber,Sinad}, Message),
            
            case {ToSelfAddressMatch, FromSelfAddressMatch} of
                {_, {ok,{self_address,_MyAddress,own,_NetMember,_NetSlot,_Channels,_WaitForReplyTime}}} ->
                    lager:debug("heard my own transmission..."),
                    NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                    {next_state, idle, NewState};                            
                {{error, not_found}, _ } ->
                    %% Not for us, just log and report
                    lager:notice("heard selcall not for us: logging as TO: ~p FROM: ~p", [ToAddr, FromAddr]),
                    
                    NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                    {next_state, idle, NewState};
                {{ok,{self_address,_MyAddress,own,_NetMember,_NetSlot,_Channels,_WaitForReplyTime}},_} ->
                    %% call request is for us;

                    case {Type, Arq} of
                        {selective, ?ARQ} ->
                            lager:notice("received selective call from ~p", [FromAddr]),
                            
                            case TxCtrlType of
                                none ->
                                    NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                                    {next_state, idle, NewState};                            
                                _ ->
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
                                    
                                    %% send selective revertive
                                    ok = send_selective_revertive(decode_subchan(SubChan)),
                                    
                                    %%                 NewState = State#state{ call_dir=inbound, 
                                    %%                                         self_address=MyAddress,
                                    %%                                         other_address=From,
                                    %%                                         reply_with_address=MyAddress,
                                    %%                                         wait_for_reply_time=NewWaitForReplyTime, 
                                    %%                                         message_state=#msg_state{}, 
                                    %%                                         timeout=NextStateTimeout},
                                    %%                 {next_state, call_wait_response_tx_complete, NewState};
                                    
                                    %% stay idle for now
                                    NewState = State#state{message_state=#msg_state{}, timeout=0},
                                    {next_state, idle, NewState}
                            end;
                        { selective, _ } ->
                            lager:warning("ARQ not requested or invalid for selective call"),
                            next_state_idle(State);
                        {channel_test, ?ARQ} ->
                            lager:notice("received channel_test call from ~p", [FromAddr]),
                            
                            case TxCtrlType of
                                none ->
                                    NewState = State#state{other_address=[], message_state=#msg_state{}, timeout=0},
                                    {next_state, idle, NewState};                            
                                _ ->
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
                                    
                                    %% send selective revertive
                                    ok = send_beacon_revertive(decode_subchan(SubChan)),
                                    
                                    %%                 NewState = State#state{ call_dir=inbound, 
                                    %%                                         self_address=MyAddress,
                                    %%                                         other_address=From,
                                    %%                                         reply_with_address=MyAddress,
                                    %%                                         wait_for_reply_time=NewWaitForReplyTime, 
                                    %%                                         message_state=#msg_state{}, 
                                    %%                                         timeout=NextStateTimeout},
                                    %%                 {next_state, call_wait_response_tx_complete, NewState};
                                    
                                    %% stay idle for now
                                    NewState = State#state{message_state=#msg_state{}, timeout=0},
                                    {next_state, idle, NewState}
                            end;
                        { channel_test, _ } ->
                            lager:warning("ARQ not requested or invalid for beacon call"),
                            next_state_idle(State);
                        { _, _ } ->
                            lager:warning("unsupported call type"),
                            next_state_idle(State)
                    end;
                Others ->
                    lager:warning("idle: improper message sections: ~p",[Others]),
                    next_state_idle(State)
            end;
        incomplete ->
            lager:warning("received incomplete message, ignoring..."),
            next_state_idle(State)
    end;
idle({call, Frequency, SubChan, ToAddr, Retries}, State=#state{transmit_control=TxCtrlType}) ->
    case TxCtrlType of
        none ->
            lager:error("Cannot sound with no transmit control defined!"),
            next_state_idle(State);
        _ ->
            lager:debug("individual call request"),
            
            SelfAddress = radio_db:read_config(selcall_id),
            OtherAddressMatch = radio_db:read_other_address(ToAddr),
            
            %% for now, we're only using this lookup to determine waitforreplytime, later
            %% channels, netmember, slots, etc. may be needed
            NewWaitForReplyTime = case OtherAddressMatch of
                                      {error, not_found} ->
                                          %% Calling station not in our database, use defaults
                                          select_wait_for_reply_time(default);
                                      {ok,{self_address,_Address,_Type,_NetMember,_NetSlot,_Channels,WaitForReplyTime}} ->
                                          %% found station in the database, use it's parameters
                                          select_wait_for_reply_time(WaitForReplyTime)
                                  end,

            %% FIXME: must cancel ALE sounding timer to prevent sounding while active on hecate
            %% erlang:cancel_timer(State#state.sound_timer_ref),

            _TxTimeMs = call(Frequency, SubChan, ?PREAMBLE_SHORT, ToAddr, SelfAddress),
            
            % spawn_notify_ale_event(ale_ind_call, EventData),
            %% NextTimeout = TxTimeMs + NewWaitForReplyTime,
            
            NewState = State#state{ %link_state=unlinked, 
                         call_dir=outbound, 
                         other_address=ToAddr,
                         self_address=SelfAddress,
                         reply_with_address=SelfAddress,
                         wait_for_reply_time=NewWaitForReplyTime,
                         subchan=SubChan,
                         freq=Frequency,
                         amd=[],
                         call_type=non_scanning,
                         retries=Retries - 1},
            {next_state, call_wait_tx_complete, NewState}
        end;
idle({page, _Message, _Retries}, State) ->
    lager:error("not implemented"),    
    next_state_idle(State);    
idle(timeout, State) ->
    lager:debug("Got timeout in idle state??"),
    next_state_idle(State).

call_wait_tx_complete({rx_msg, _Msg}, State) ->
    lager:debug("ignoring rx message while waiting for tx_complete (probably our own)"),
    {next_state, call_wait_tx_complete, State};
call_wait_tx_complete({rx_revertive, Frequency}, State) ->
    lager:debug("detected revertive while waiting for tx_complete on ~p",[Frequency]),
    {next_state, call_wait_tx_complete, State};
call_wait_tx_complete({tx_complete}, State=#state{wait_for_reply_time=WaitForReplyTime}) ->
    lager:debug("got tx_complete"),
    %% Time to turn off transmitter and switch back to RX
    {ok, off} = radio_control_port:transmit_control(State#state.transmit_control, off),    
    NewMessageState = #msg_state{},
    NewState = State#state{message_state=NewMessageState, timeout=WaitForReplyTime},
    {next_state, call_wait_revertive_response, NewState, WaitForReplyTime}.

%%
%% Wait for revertive response
%%
call_wait_revertive_response({rx_msg, _Msg}, State=#state{wait_for_reply_time=WaitForReplyTime}) ->
    lager:debug("ignoring rx message while waiting for revertive (probably our own)"),
    {next_state, call_wait_revertive_response, State, WaitForReplyTime};
call_wait_revertive_response({rx_revertive, Frequency}, State=#state{ %link_state=LinkState, 
                                                                      freq=Frequency}) ->
                                                                      %call_dir=CallDir, 
                                                                      %other_address=OtherAddress, 
                                                                      %self_address=MyAddress,
                                                                      %reply_with_address=ReplyWithAddress,
                                                                      %message_state=MessageState, 
                                                                      %timeout=Timeout}) ->
    %% got revertive on the Frequency we're calling on
    lager:info("Heard TX revertive, going back idle for now"),
    next_state_idle(State);
call_wait_revertive_response({rx_revertive, OtherFrequency}, State=#state{ %link_state=LinkState, 
                                                                      %freq=Frequency,
                                                                      %call_dir=CallDir, 
                                                                      %other_address=OtherAddress, 
                                                                      %self_address=MyAddress,
                                                                      %reply_with_address=ReplyWithAddress
                                                                      wait_for_reply_time=WaitForReplyTime
                                                                      %message_state=MessageState, 
                                                                      %timeout=Timeout
                                                                     }) ->
    %% got revertive on different Frequency from what we're calling on
    lager:debug("Heard TX revertive, but wrong freq (~p)...still waiting",[OtherFrequency]),
    {next_state, call_wait_revertive_response, State, WaitForReplyTime};
call_wait_revertive_response(timeout, State=#state{ %link_state=LinkState, 
                                                %call_dir=CallDir, 
                                               other_address=OtherAddress, 
                                                %self_address=MyAddress,
                                                %reply_with_address=ReplyWithAddress,
                                                %message_state=MessageState, 
                                                %timeout=Timeout,
                                               subchan=SubChan,
                                               freq=Frequency,
                                                %amd=AMDMessage,
                                                %call_type=CallType,
                                               retries=Retries}) ->
    RetriesLeft = Retries > 0,
    case RetriesLeft of
        true  ->
            gen_fsm:send_event(hecate, {call, Frequency, SubChan, OtherAddress, Retries}),
            next_state_idle(State);
        false ->
            lager:warning("IMPLEMENT ME: call response timeout, alert user"),
            NewState=State#state{},             
            next_state_idle(NewState)
    end.



%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Function to determine HFLink reporting smeter string. As per Alan Barrow KM4BA alan@pinztrek.com
%% BER icon:
%% Smeter icons will be included if the smeter keywork is appended to the
%% frame and in the exact engineering format. They specific keywords should
%% be sent based on the following BER levels:
%%          " smeter4" if ( $line =~ /BER 27|BER 28|BER 29/ );
%%          " smeter3" if ( $line =~ /BER 24|BER 25|BER 26/ );
%%          " smeter2" if ( $line =~ /BER 21|BER 22|BER 23/ );
%%          " smeter1" if ( $line =~ /BER 0\d|BER 1\d|BER 20/ );
get_smeter_string(Ber) when Ber > 29 ->
    "smeter5";
get_smeter_string(Ber) when Ber > 26 ->
    "smeter4";        
get_smeter_string(Ber) when Ber > 23 ->
    "smeter3";
get_smeter_string(Ber) when Ber > 20 ->
    "smeter2";
get_smeter_string(_Ber) ->
    "smeter1".


%% Used to notify user control device of an ALE event
notify_hecate_event(Event, Data) ->
    case whereis(backend_handler) of
        undefined -> lager:info("backend_handler not registered");
        _ ->
            % lager:debug("~p",[[{event,Event},{data, Data}]]),
            Msg = backend_handler:build_response([{event,Event},Data]),
            backend_handler ! {data, Msg}
    end.    

spawn_notify_hecate_event(Event, Data) ->
    _Pid = spawn(hecate, notify_hecate_event, [Event, Data]).


send_hflink_report(ReportString) ->
    {ok, Result } = httpc:request(post, {"http://hflink.net/log/postit.php", [],
                                         "application/x-www-form-urlencoded", ReportString},[],[]),
    lager:debug("POST Result: ~p",[Result]).

spawn_send_hflink_report(ReportString) ->
    _Pid = spawn(hecate, send_hflink_report, [ReportString]).

spawn_store_lqa_and_report(Freq, To, Conclusion, {Ber, Sinad}, Message) ->
    _Pid = spawn(hecate, store_lqa_and_report, [Freq, To, Conclusion, {Ber, Sinad}, Message]).

store_lqa_and_report(Freq, To, From, {Ber, Sinad}, Message) ->
    %% TODO: compute LQA and store in DB?
    %% [Type|Id] = Conclusion,
    %% TypeString = string:to_upper(atom_to_list(Type)),
    lager:info("heard: To: ~p From: ~p:~p BER: ~p SINAD: ~p Frequency: ~p, Message: ~p",[To, "TIS",From,Ber,Sinad,Freq,Message]),

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

    {Megasec,Sec,Micro} = os:timestamp(),
    Timestamp = Megasec * 1000000 + Sec,
    
    %% store it in the contact database
    Contact = 	#contact{ id 			    = From, %% store directly as a number
                          time 		    = Timestamp,
                          channel 	  = Channel,
                          frequency 	= Freq,
                          ber 		    = Ber,
                          sinad 		  = Sinad,
                          name 		    = Name,
                          coordinates = Coordinates,
                          power 		  = Power,
                          radio 		  = Radio,
                          controller 	= Controller,
                          antenna 	  = Antenna
                        },
    
    %% TODO: There may be many contacts for a given Id, but on different
    %% frequencies and with different BERs. For now just store the latest for
    %% Id, then if user wants to contact, look into LQA database to determine
    %% best freq and possibly route.
    {atomic, _} = radio_db:write_contact(Contact),
    lager:debug("wrote contact to db"),
    
    %% format log message
    {{_Year, _Month, _Day},{H,M,S}} = calendar:now_to_universal_time({Megasec,Sec,Micro}),
    
    Formatted = io_lib:format("[~.2.0w:~.2.0w:~.2.0w][FRQ ~p][TO][~p][TIS][~p][AL0]", [H,M,S,Freq,To,From]),
    lager:notice("~s", [Formatted]),
    
    %%
    %% "nick=K6DRS&shout=%5B20%3A23%3A35%5D%5BFRQ+18106000%5D%5BSND%5D%5BTWS%5D%5BK6DRS%5D%5BAL0%5D+BER+24+SN+03+smeter3&email=linker&send=&Submit=send"
    %%
    %% POST to: http://hflink.net/log/postit.php
    %% check the DB to determine if HFLink reporting is enabled
    
    %% get myID from database
    MyId = radio_db:read_config(id),
    ReportHeader = io_lib:format("nick=HFS ~s&shout=",[MyId]),
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
    
    %% If control device is connected, send it the contact and log event
    %% format and send this contact to control device

    %% must handle case where SELCALL addresses are stored, since
    %% these are just integers and cause problems for to_json()
    NewContact = case is_number(Contact#contact.id) of
                     true -> 
                         Contact#contact{id = integer_to_binary(Contact#contact.id)};
                     false ->
                         Contact
                 end,

    ContactEJSON = contact:to_json(NewContact),
    %% build contact message
    spawn_notify_hecate_event(ale_new_contact, {data,jsx:encode(ContactEJSON)}),
    spawn_notify_hecate_event(ale_rx_sound, {data,list_to_binary(Formatted)}).

%%% Count parity errors
%%% Check each word in a list for the bad word flag. Build an output
%%% list that contains only word that don't have the bad word flag
%%% set.
bad_word_check([], Output) ->
    Output;
bad_word_check([Head|Tail], Output) when Head band ?BAD_WORD == 0 ->
    GoodWord = Head band 127,
    bad_word_check(Tail, [GoodWord|Output]);
bad_word_check([_Head|Tail], Output) ->
    bad_word_check(Tail, Output).

%% Given a list of candidate word values, find the most common word
%% and return it. This performs majority voting of a list of possible
%% word values.
majority_vote([]) ->
    {error,error};
majority_vote(List) ->
    [Majority|_SortedWordFreqs] = lists:reverse(lists:keysort(2,lists:foldl(fun (C, D) -> orddict:update_counter(C, 1, D) end, orddict:new(),List))),
    Majority.

check_page_chars([Word|Footer], Message) when (Word band 127) == ?ARQ ->
    {lists:reverse(Message), lists:reverse(Footer)}; %% Footer may contain a list of 117...SinadFreqWord, put SinadFreqWord first
check_page_chars([Word|Words], Message) ->
    Checked = case bad_word_check([Word],[]) of
                  [] ->
                      176; % ASCII block character to mark invalid
                  [Good] ->
                      Good
              end,
    check_page_chars(Words, [Checked | Message]).
    

%%
%% Receive SELCALL message. Validate characters, addresses, call type, message section...
%%
receive_msg(Msg) ->
    <<Sel1:32/unsigned-little-integer,
      Sel2:32/unsigned-little-integer,
      B1_1:32/unsigned-little-integer,
      Sel3:32/unsigned-little-integer,
      B2_1:32/unsigned-little-integer,
      Sel4:32/unsigned-little-integer,
      Rest/binary>> = Msg,
    SelList = bad_word_check([Sel1,Sel2,Sel3,Sel4],[]),
    {Sel,_Count} = majority_vote(SelList),
    case Sel of
        ?SEL ->
            %% At this point it could be a Selective Call, or a Selective Page Call
            <<Cat1:32/unsigned-little-integer,
              B1_2:32/unsigned-little-integer,
              A1_1:32/unsigned-little-integer,
              B2_2:32/unsigned-little-integer,
              A2_1:32/unsigned-little-integer,
              Cat2:32/unsigned-little-integer,
              Arq1:32/unsigned-little-integer,
              A1_2:32/unsigned-little-integer,
              Arq2:32/unsigned-little-integer,
              A2_2:32/unsigned-little-integer,
              Arq3:32/unsigned-little-integer,
              Arq4:32/unsigned-little-integer, Rest2/binary>> = Rest,
            
            CatList = bad_word_check([Cat1,Cat2],[]),
            {Cat,_} = majority_vote(CatList),
            B1List = bad_word_check([B1_1,B1_2],[]),
            {B1,_} = majority_vote(B1List),
            B2List = bad_word_check([B2_1,B2_2],[]),
            {B2,_} = majority_vote(B2List),
            A1List = bad_word_check([A1_1,A1_2],[]),
            {A1,_} = majority_vote(A1List),
            A2List = bad_word_check([A2_1,A2_2],[]),
            {A2,_} = majority_vote(A2List),
            ArqList = bad_word_check([Arq1,Arq2,Arq3,Arq4],[]),
            {Arq,_} = majority_vote(ArqList),
            
            case Arq of
                ?ARQ ->
                    %% We have a complete selective call
                    <<Footer:32/unsigned-little-integer>> = Rest2,
                    <<SubChan:2,Sinad:5,Frequency:25>> = <<Footer:32>>,
                    %% lager:info("SELCALL Footer=~p",[Footer]),
                    case B1 /= error 
                        andalso B2 /= error 
                        andalso A1 /= error 
                        andalso B2 /= error of
                        true ->
                            To = B1 * 100 + B2,
                            From = A1 * 100 + A2,
                            
                            #msg_state{status=complete,
                                       type=selective,
                                       category=Cat,
                                       to=To,
                                       from=From,
                                       arq=Arq,
                                       message=[],
                                       subchan=SubChan,
                                       sinad=Sinad,
                                       frequency=Frequency};
                        false ->
                            lager:warning("received SELCALL message with errors: TO: ~p FROM: ~p", [{B1,B2},{A1,A2}]),
                            #msg_state{}
                    end;
                ?PAG ->
                    %% this is a page call
                    D00 = Arq2,
                    D01 = Arq3,
                    %% All page data characters + ARQ + Footer
                    MessageContent = <<D00:32/unsigned-little-integer,D01:32/unsigned-little-integer,Rest2/binary>>,
                    lager:debug("MessageContent=~p",[MessageContent]),
                    MessageContentList = [ X || <<X:32/unsigned-little-integer>> <= MessageContent],
                    {Message, [Footer|_]} = check_page_chars(MessageContentList,[]),
                    lager:info("Message=~p,Footer=~p",[Message,Footer]),
                    <<SubChan:2,Sinad:5,Frequency:25>> = <<Footer:32>>,
                    case B1 /= error 
                        andalso B2 /= error 
                        andalso A1 /= error 
                        andalso B2 /= error of
                        true ->
                            To = B1 * 100 + B2,
                            From = A1 * 100 + A2,
                            
                            #msg_state{status=complete,
                                       type=selective,
                                       category=Cat,
                                       to=To,
                                       from=From,
                                       arq=?ARQ, %% known to be 117 at this point
                                       message=Message,
                                       subchan=SubChan,
                                       sinad=Sinad,
                                       frequency=Frequency};
                        false ->
                            lager:warning("received PAGECALL message with errors: TO: ~p FROM: ~p, Message=~p", [{B1,B2},{A1,A2}, Message]),
                            #msg_state{}
                    end
            end;
        ?TST ->
            <<Cat1:32/unsigned-little-integer,
              B1_2:32/unsigned-little-integer,
              A1_1:32/unsigned-little-integer,
              B2_2:32/unsigned-little-integer,
              A2_1:32/unsigned-little-integer,
              Cat2:32/unsigned-little-integer,
              Arq1:32/unsigned-little-integer,
              A1_2:32/unsigned-little-integer,
              Arq2:32/unsigned-little-integer,
              A2_2:32/unsigned-little-integer,
              Arq3:32/unsigned-little-integer,
              Arq4:32/unsigned-little-integer, 
              Footer:32/unsigned-little-integer>> = Rest,
              <<SubChan:2,Sinad:5,Frequency:25>> = <<Footer:32>>,
            % lager:info("TST Footer=~p",[Footer]),
            CatList = bad_word_check([Cat1,Cat2],[]),
            {Cat,_} = majority_vote(CatList),
            B1List = bad_word_check([B1_1,B1_2],[]),
            {B1,_} = majority_vote(B1List),
            B2List = bad_word_check([B2_1,B2_2],[]),
            {B2,_} = majority_vote(B2List),
            A1List = bad_word_check([A1_1,A1_2],[]),
            {A1,_} = majority_vote(A1List),
            A2List = bad_word_check([A2_1,A2_2],[]),
            {A2,_} = majority_vote(A2List),
            ArqList = bad_word_check([Arq1,Arq2,Arq3,Arq4],[]),
            {Arq,_} = majority_vote(ArqList),
            case B1 /= error 
                andalso B2 /= error 
                andalso A1 /= error 
                andalso B2 /= error of
                true ->
                    To = B1 * 100 + B2,
                    From = A1 * 100 + A2,
                    
                    #msg_state{status=complete,
                               type=channel_test,
                               category=Cat,
                               to=To,
                               from=From,
                               arq=Arq,
                               message=[],
                               subchan=SubChan,
                               sinad=Sinad,
                               frequency=Frequency};
                false ->
                    lager:warning("received SELCALL message with errors: TO: ~p FROM: ~p", [{B1,B2},{A1,A2}]),
                    #msg_state{}
            end;    
        _ ->
            lager:warning("unsupported SELCALL message type received: ~p", [Sel]),
            #msg_state{}
    end.


words_to_bin([], Bin) ->
    Bin;
words_to_bin([Word|Words], Bin) ->
    NewBin = <<Bin/binary, Word:32/unsigned-little-integer>>,
    words_to_bin(Words, NewBin).

%% Duration is in milliseconds, Samplerate is in samples/sec
generate_dot_pattern(Duration, Samplerate) ->
    SamplesPerSymbol = Samplerate / 100, %% 100 symbols per second
    DurationInSamples = (Duration/1000.0) * Samplerate,
    TotalRequiredSymbols = DurationInSamples / SamplesPerSymbol,
    TotalRequiredChars = TotalRequiredSymbols / 10, %% ten bit characters
    [ 341 || _X <- lists:seq(1, trunc(TotalRequiredChars))].

encode_selcall(PreambleLen, ToAddr, OwnAddr) when is_number(ToAddr) andalso is_number(OwnAddr) -> 
    %% Ten bit character encoding for CCIR-493 

    CCIR_493_Code_Table = [7, 518, 262, 773, 134, 645, 389, 900,
                           70, 581, 325, 836, 197, 708, 452, 963, 38, 549, 293, 804, 165, 676,
                           420, 931, 101, 612, 356, 867, 228, 739, 483, 994, 22, 533, 277, 788,
                           149, 660, 404, 915, 85, 596, 340, 851, 212, 723, 467, 978, 53, 564,
                           308, 819, 180, 691, 435, 946, 116, 627, 371, 882, 243, 754, 498, 1009,
                           14, 525, 269, 780, 141, 652, 396, 907, 77, 588, 332, 843, 204, 715,
                           459, 970, 45, 556, 300, 811, 172, 683, 427, 938, 108, 619, 363, 874,
                           235, 746, 490, 1001, 29, 540, 284, 795, 156, 667, 411, 922, 92, 603,
                           347, 858, 219, 730, 474, 985, 60, 571, 315, 826, 187, 698, 442, 953,
                           123, 634, 378, 889, 250, 761, 505, 1016],

    %% extract the address digits for to and from addresses
    B1 = trunc(ToAddr / 100),
    B2 = ToAddr rem 100,
    A1 = trunc(OwnAddr / 100),
    A2 = OwnAddr rem 100,
    
    %% define / encode remaining message symbols
    % Sel = 120, %% selective call format specifier
    % Rtn = 100, %% catagory, routine
    % Arq = 117, %% Ack request

    %% generate the dot sequence bytes
    DotSequence = generate_dot_pattern(PreambleLen, 8000),

    %% Phasing sequence section of message
    Phasing_Seq = [125, 109, 125, 108, 125, 107, 125, 106, 125, 105, 125, 104 ],

    %% Address / command section
    AddrCmd = [?SEL,?SEL,B1,?SEL,B2,?SEL,?RTN,B1,A1,B2,A2,?RTN,?ARQ,A1,?ARQ,A2,?ARQ,?ARQ],

    %% Prepend phasing sequence to AddrCmd
    PhasingAddrCmd = lists:flatten([Phasing_Seq | AddrCmd]),
    % lists:flatten([Phasing_Seq | AddrCmd]);

    % io:format("PhasingAddrCmd=~p~n",[PhasingAddrCmd]),

    %% encode the phasing sequence (NOTE: nth() expects 1-origin, so add 1 to all X values!!)
    PhasingAddrCmd_enc = [ lists:nth((X+1),CCIR_493_Code_Table) || X <- PhasingAddrCmd ],

    %% Prepend dot sequence and return words
    lists:flatten([DotSequence | PhasingAddrCmd_enc]);
encode_selcall(_, _, _) ->
    io:format("invalid address specified").

%% beacon_call_msg = [TST, TST, B1, TST, B2, TST, RTN, B1, A1, B2, A2, RTN, ARQ, A1, ARQ, A2, ARQ, ARQ]
encode_beacon_call(PreambleLen, ToAddr, OwnAddr) when is_number(ToAddr) andalso is_number(OwnAddr) ->
    %% Ten bit character encoding for CCIR-493
    CCIR_493_Code_Table = [7, 518, 262, 773, 134, 645, 389, 900, 70,
    581, 325, 836, 197, 708, 452, 963, 38, 549, 293, 804, 165, 676,
    420, 931, 101, 612, 356, 867, 228, 739, 483, 994, 22, 533, 277,
    788, 149, 660, 404, 915, 85, 596, 340, 851, 212, 723, 467, 978,
    53, 564, 308, 819, 180, 691, 435, 946, 116, 627, 371, 882, 243,
    754, 498, 1009, 14, 525, 269, 780, 141, 652, 396, 907, 77, 588,
    332, 843, 204, 715, 459, 970, 45, 556, 300, 811, 172, 683, 427,
    938, 108, 619, 363, 874, 235, 746, 490, 1001, 29, 540, 284, 795,
    156, 667, 411, 922, 92, 603, 347, 858, 219, 730, 474, 985, 60,
    571, 315, 826, 187, 698, 442, 953, 123, 634, 378, 889, 250, 761,
    505, 1016],

    %% extract the address digits for to and from addresses
    B1 = trunc(ToAddr / 100),
    B2 = ToAddr rem 100,
    A1 = trunc(OwnAddr / 100),
    A2 = OwnAddr rem 100,
    
    %% define / encode remaining message symbols
    % Tst = 123, %% Beacon call format specifier
    % Rtn = 100, %% catagory, routine
    % Arq = 117, %% Ack request

    %% generate the dot sequence bytes
    DotSequence = generate_dot_pattern(PreambleLen, 8000),

    %% Phasing sequence section of message
    Phasing_Seq = [125, 109, 125, 108, 125, 107, 125, 106, 125, 105, 125, 104 ],

    %% Address / command section
    AddrCmd = [?TST,?TST,B1,?TST,B2,?TST,?RTN,B1,A1,B2,A2,?RTN,?ARQ,A1,?ARQ,A2,?ARQ,?ARQ],

    %% Prepend phasing sequence to AddrCmd
    PhasingAddrCmd = lists:flatten([Phasing_Seq | AddrCmd]),

    %% encode the phasing sequence (NOTE: nth() expects 1-origin, so add 1 to all X values!!)
    PhasingAddrCmd_enc = [ lists:nth((X+1),CCIR_493_Code_Table) || X <- PhasingAddrCmd ],

    %% Prepend dot sequence and return words
    lists:flatten([DotSequence | PhasingAddrCmd_enc]);
encode_beacon_call(_, _, _) ->
    io:format("invalid address specified").

encode_page_call(PreambleLen, ToAddr, OwnAddr, Message) when is_number(ToAddr) andalso is_number(OwnAddr) -> 
    %% Ten bit character encoding for CCIR-493
    CCIR_493_Code_Table = [7, 518, 262, 773, 134, 645, 389, 900, 70,
      581, 325, 836, 197, 708, 452, 963, 38, 549, 293, 804, 165, 676,
      420, 931, 101, 612, 356, 867, 228, 739, 483, 994, 22, 533, 277,
      788, 149, 660, 404, 915, 85, 596, 340, 851, 212, 723, 467, 978,
      53, 564, 308, 819, 180, 691, 435, 946, 116, 627, 371, 882, 243,
      754, 498, 1009, 14, 525, 269, 780, 141, 652, 396, 907, 77, 588,
      332, 843, 204, 715, 459, 970, 45, 556, 300, 811, 172, 683, 427,
      938, 108, 619, 363, 874, 235, 746, 490, 1001, 29, 540, 284, 795,
      156, 667, 411, 922, 92, 603, 347, 858, 219, 730, 474, 985, 60,
      571, 315, 826, 187, 698, 442, 953, 123, 634, 378, 889, 250, 761,
      505, 1016],

    %% to and from addresses
    B1 = trunc(ToAddr / 100),
    B2 = ToAddr rem 100,
    A1 = trunc(OwnAddr / 100),
    A2 = OwnAddr rem 100,
    
    %% define / encode remaining message symbols
    % Sel = ?SEL, %% Beacon call format specifier
    % Rtn = ?RTN, %% catagory, routine
    % Arq = ?ARQ, %% Ack request
    % Pag = ?PAG, %% Paging data indicator

    %% generate the dot sequence bytes
    DotSequence = generate_dot_pattern(PreambleLen, 8000),

    %% Phasing sequence section of message
    Phasing_Seq = [125, 109, 125, 108, 125, 107, 125, 106, 125, 105, 125, 104],

    %% pull first two chars
    [D00|MsgRest1] = Message,
    [D01|MsgRest2] = MsgRest1,

    %% Address / command section 
    AddrCmd = [?SEL,?SEL,B1,?SEL,B2,?SEL,?RTN,B1,A1,B2,A2,?RTN,?PAG,A1,D00,A2,D01,?PAG],

    %% The termination for open selective page call
    Termination = [?ARQ,?ARQ,?ARQ,?ARQ,?ARQ],

    %% Prepend phasing sequence to AddrCmd 
    PhasingAddrCmd = lists:flatten([Phasing_Seq,AddrCmd,MsgRest2,Termination]),

    %% encode the phasing sequence (NOTE: nth() expects 1-origin, so add 1 to all X values!!)
    PhasingAddrCmd_enc = [ lists:nth((X+1),CCIR_493_Code_Table) || X <- PhasingAddrCmd ],

    %% Prepend dot sequence and return words
    lists:flatten([DotSequence | PhasingAddrCmd_enc]);
encode_page_call(_, _, _, _) ->
    io:format("invalid address specified").
    

send_selective_revertive(SubChan) ->
    %% should be 900 Hz 750ms second, 50ms gap, then 650 Hz 125ms with 125ms gaps 
    Tone1_Freq = 900,
    Tone1_Duration = 6000,
    Gap1_Duration = 400,
    Tone2_Freq = 650,
    Tone2_Duration = 1000,
    Gap2_Duration = 1000,

    Tone1_Cmd = (Tone1_Duration bsl 16) bor Tone1_Freq,
    Gap1_Cmd = Gap1_Duration bsl 16, %% frequency of gap is zero
    Tone2_Cmd = (Tone2_Duration bsl 16) bor Tone2_Freq,
    Gap2_Cmd = Gap2_Duration bsl 16, %% frequency of gap is zero
    
    send_tone(Tone1_Cmd),
    send_tone(Gap1_Cmd),
    send_tone(Tone2_Cmd),
    send_tone(Gap2_Cmd),
    send_tone(Tone2_Cmd),
    send_tone(Gap2_Cmd),
    send_tone(Tone2_Cmd),
    send_tone(Gap2_Cmd),
    send_tone(Tone2_Cmd),
    send_tone(Gap2_Cmd).


send_beacon_revertive(SubChan) ->
    %% should be 800 Hz 1 second each, 4X with 250ms gaps
    Tone1_Freq = 800,
    Tone1_Duration = 8000,
    Gap1_Duration = 2000,

    Tone1_Cmd = (Tone1_Duration bsl 16) bor Tone1_Freq,
    Gap1_Cmd = Gap1_Duration bsl 16, %% frequency of gap is zero
    
    send_tone(Tone1_Cmd),
    send_tone(Gap1_Cmd),
    send_tone(Tone1_Cmd),
    send_tone(Gap1_Cmd),
    send_tone(Tone1_Cmd),
    send_tone(Gap1_Cmd),
    send_tone(Tone1_Cmd),
    send_tone(Gap1_Cmd).

send_gap(a, GapMs) ->
    send_gap_cmd(<<"DT03">>, GapMs);
send_gap(b, GapMs) ->
    send_gap_cmd(<<"DT05">>, GapMs);
send_gap(c, GapMs) ->
    send_gap_cmd(<<"DT07">>, GapMs).    

send_gap_cmd(SubChanCmd,GapMs) ->
    MsPerSymbol = 10,
    Symbols = round(GapMs / MsPerSymbol),
    MsgCmdType = SubChanCmd,
    MsgCmdTerm = <<";">>,
    MsgBin = <<Symbols:32/unsigned-little-integer>>,
    MsgCmd = << MsgCmdType/binary, MsgBin/binary, MsgCmdTerm/binary  >>,
    message_server_proc ! {cmd, MsgCmd},
    ok.

send_words(a, Words) ->
    MsgCmdType = <<"DT02">>,
    send_words_cmd(MsgCmdType, Words);
send_words(b, Words) ->
    MsgCmdType = <<"DT04">>,
    send_words_cmd(MsgCmdType, Words);
send_words(c, Words) ->
    MsgCmdType = <<"DT06">>,
    send_words_cmd(MsgCmdType, Words).

send_tone(Word) ->
    MsgCmdType = <<"DT08">>,
    send_tone_cmd(MsgCmdType, Word).

send_tone_cmd(Cmd, Word) ->
    MsgCmdTerm = <<";">>,
    MsgBin = <<Word:32/unsigned-little-integer>>,
    MsgCmd = << Cmd/binary, MsgBin/binary, MsgCmdTerm/binary  >>,
    message_server_proc ! {cmd, MsgCmd},
    ok.

send_words_cmd(MsgCmdType,Words) ->
    MsgCmdTerm = <<";">>,
    MsgBin = words_to_bin(Words, <<>>),
    MsgCmd = << MsgCmdType/binary, MsgBin/binary, MsgCmdTerm/binary  >>,
    message_server_proc ! {cmd, MsgCmd},
    ok.

abort_tx() ->
    MsgCmd = <<"AB;">>,
    message_server_proc ! {cmd, MsgCmd},
    ok.

%%
%% Radio control TX handling
%%
transmit_control(none, Mode) ->
    %% do nothing, no radio to control
    {ok, Mode};
transmit_control(internal, Mode) ->
    lager:debug("radio control internal not yet implemented"),
    {ok, Mode};
transmit_control(external, on) ->
    radio_control_port:rf_switch(on),
    radio_control_port:set_ptt(on);
transmit_control(external, off) ->
    radio_control_port:set_ptt(off),
    timer:sleep(50), %%% <<== THIS DELAY REQUIRED TO PREVENT RF GLITCH FROM HARMING RX
    radio_control_port:rf_switch(off).

%%
%% PA control handling
%%
pa_control_set_freq(none, Freq) ->
    {ok, Freq};
pa_control_set_freq(external, Freq) ->
    pa_control_port:set_freq(Freq).

tune_transmitter(none, Chan) ->
    %% no radio (transmitter) to tune
    Chan#channel.frequency;
tune_transmitter(internal, Chan) ->
    lager:debug("internal tune radio not implemented"),
    Chan#channel.frequency;
tune_transmitter(external, Chan) ->
    ChanFreq = Chan#channel.frequency,
    {ok, _Ret2} = radio_control_port:set_chan(Chan#channel.id),
    {ok, _Ret3} = radio_control_port:set_freq(ChanFreq),
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

transmitter_mode(none, _Chan) ->
    %% no transmitter
    ok;
transmitter_mode(internal, _Chan) ->
    lager:debug("internal tune radio not implemented"),
    ok;
transmitter_mode(external, Chan) when Chan#channel.sideband == <<"LSB">> ->
    {ok, _Ret3} = radio_control_port:set_mode(1),
    ok;
transmitter_mode(external, Chan) when Chan#channel.sideband == <<"USB">> ->
    {ok, _Ret3} = radio_control_port:set_mode(2),
    ok.

%% SubChan: Which subchannel to use
%% PreambleLength: Dot sequence length
%% ToAddr: address of station being called
%% FromAddr: address of calling station
call(Freq, SubChan, PreambleLen, ToAddr, FromAddr) ->
    MatchList = radio_db:find_channel(Freq),
    case MatchList of
        [] ->
            lager:warning("no matching channel found, assuming VFO mode?");
        [ChanRecord|_Rest] ->
            Frequency = tune_transmitter(external, ChanRecord),
            Frequency = tune_pa(external, ChanRecord),
            ok = transmitter_mode(external, ChanRecord)
        end,    
    {ok, on} = transmit_control(external, on),
    Words = encode_selcall(PreambleLen, ToAddr, FromAddr),  
    ok = send_words(SubChan,Words), 
    %% To ensure signal is not truncated by TX shutdown (due to soundcard latency 
    %% tx_complete can be received before all is played out).
    ok = send_gap(SubChan,200),
    length(Words) * 10 * ?SYMBOL_LENGTH_MS + 200.    

%% SubChan: Which subchannel to use
%% PreambleLength: Dot sequence length
%% ToAddr: address of station being called
%% FromAddr: address of calling station
test(Freq, SubChan, PreambleLen, ToAddr, FromAddr) ->
    MatchList = radio_db:find_channel(Freq),
    case MatchList of
        [] ->
            lager:warning("no matching channel found, assuming VFO mode?");
        [ChanRecord|_Rest] ->
            Frequency = tune_transmitter(external, ChanRecord),
            Frequency = tune_pa(external, ChanRecord),
            ok = transmitter_mode(external, ChanRecord)
        end,    
    {ok, on} = transmit_control(external, on),
    Words = encode_beacon_call(PreambleLen, ToAddr, FromAddr),  
    ok = send_words(SubChan,Words), 
    %% To ensure signal is not truncated by TX shutdown (due to soundcard latency 
    %% tx_complete can be received before all is played out).
    ok = send_gap(SubChan,200),
    length(Words) * 10 * ?SYMBOL_LENGTH_MS + 200.

%% SubChan: Which subchannel to use
%% PreambleLength: Dot sequence length
%% ToAddr: address of station being called
%% FromAddr: address of calling station
page(Freq, SubChan, PreambleLen, ToAddr, FromAddr, Message) ->
    MatchList = radio_db:find_channel(Freq),
    case MatchList of
        [] ->
            lager:warning("no matching channel found, assuming VFO mode?");
        [ChanRecord|_Rest] ->
            Frequency = tune_transmitter(external, ChanRecord),
            Frequency = tune_pa(external, ChanRecord),
            ok = transmitter_mode(external, ChanRecord)
        end,    
    {ok, on} = transmit_control(external, on),
    Words = encode_page_call(PreambleLen, ToAddr, FromAddr, Message),  
    ok = send_words(SubChan,Words), 
    %% To ensure signal is not truncated by TX shutdown (due to soundcard latency 
    %% tx_complete can be received before all is played out).
    ok = send_gap(SubChan,200),
    length(Words) * 10 * ?SYMBOL_LENGTH_MS + 200.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, ok, StateName, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    lager:notice("got terminate, exiting..."),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.
