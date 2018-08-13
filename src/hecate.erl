%%
%% HECATE HFLink sidechannel SELCALL (CCIR-493) support 
%%

-module(hecate).

-export([   generate_dot_pattern/2
        ,   encode_selcall/3
        ,   send_gap/2
        ,   send_words/2
        ,   abort_tx/0
        ,   call/5
        ]).

-include("radio.hrl").

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
    CCIR_493_Code_Table = [7, 518, 262, 773, 134, 645, 389, 900, 70, 581, 325, 836, 197, 708, 452, 963, 38, 549, 293, 804, 165, 676, 420, 931, 101, 612, 356, 867, 228, 739, 483, 994, 22, 533, 277, 788, 149, 660, 404, 915, 85, 596, 340, 851, 212, 723, 467, 978, 53, 564, 308, 819, 180, 691, 435, 946, 116, 627, 371, 882, 243, 754, 498, 1009, 14, 525, 269, 780, 141, 652, 396, 907, 77, 588, 332, 843, 204, 715, 459, 970, 45, 556, 300, 811, 172, 683, 427, 938, 108, 619, 363, 874, 235, 746, 490, 1001, 29, 540, 284, 795, 156, 667, 411, 922, 92, 603, 347, 858, 219, 730, 474, 985, 60, 571, 315, 826, 187, 698, 442, 953, 123, 634, 378, 889, 250, 761, 505, 1016],

    %% extract the address digits for to and from addresses
    B1 = trunc(ToAddr / 100),
    B2 = ToAddr rem 100,
    A1 = trunc(OwnAddr / 100),
    A2 = OwnAddr rem 100,
    
    %% define / encode remaining message symbols
    Sel = 120, %% selective call format specifier
    Rtn = 100, %% catagory, routine
    Arq = 117, %% Ack request

    %% generate the dot sequence bytes
    DotSequence = generate_dot_pattern(PreambleLen, 8000),

    %% Phasing sequence section of message
    Phasing_Seq = [125, 109, 125, 108, 125, 107, 125, 106, 125, 105, 125, 104 ],

    %% Address / command section
    AddrCmd = [Sel,Sel,B1,Sel,B2,Sel,Rtn,B1,A1,B2,A2,Rtn,Arq,A1,Arq,A2,Arq,Arq],

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
    ok = send_gap(SubChan,100).
    