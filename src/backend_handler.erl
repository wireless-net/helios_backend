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

-module(backend_handler).
-behaviour(cowboy_http_handler).
-behaviour(cowboy_websocket_handler).
-export([init/3, handle/2, terminate/3]).
-export([websocket_init/3, websocket_handle/3, websocket_info/3, websocket_terminate/3 ]).
-export([build_response/1]).
% -export([radio_control_port_set_mode/1,radio_control_port_set_freq/1,pa_control_port_set_freq/1]).

-include("radio.hrl").

init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

handle(Req, State) ->
    lager:debug("Request not expected: ~p", [Req]),
    {ok, Req2} = cowboy_http_req:reply(404, [{'Content-Type', <<"text/html">>}]),
    {ok, Req2, State}.

websocket_init(_TransportName, Req, _Opts) ->
    lager:debug("init websocket"),
    register(backend_handler, self()),
    {ok, Req, undefined_state}.

build_response(RespList) ->
    build_response(RespList,[]).

build_response([],Response) ->
    jsx:encode(Response);
build_response([nothing|Tail],Response) ->
    build_response(Tail,Response);
build_response([H|Tail], Response) ->
    build_response(Tail, [H|Response]).

%%
%% Decided to remove this stuff, so main radio can operate independently of RX
%% 
% radio_control_port_set_mode(Mode) ->
%     {ok, _Ret3} = radio_control_port:set_mode(Mode),
%     ok.

% radio_control_port_set_freq(Freq) ->
%     {ok, _Ret2} = radio_control_port:set_freq(Freq),
%     ok.

% pa_control_port_set_freq(Freq) ->
%     {ok, _Ret2} = pa_control_port:set_freq(Freq),
%     ok.


% spawn_radio_control_port_set_mode(Mode) ->
%     _Pid = spawn(backend_handler, radio_control_port_set_mode, [Mode]),
%     ok.

% spawn_radio_control_port_set_freq(Freq) ->
%     _Pid = spawn(backend_handler, radio_control_port_set_freq, [Freq]),
%     ok.

% spawn_pa_control_port_set_freq(Freq) ->
%     _Pid = spawn(backend_handler, pa_control_port_set_freq, [Freq]),
%     ok.
%%
%% Fire off all contacts to control device websocket that are within the last 24 hours
%%
send_daily_contacts([]) ->
    ok;
send_daily_contacts([Contact|ContactList]) ->
    {Megasec,Sec,_Micro} = os:timestamp(),
    Timestamp = Megasec * 1000000 + Sec,
    send_daily_contacts([Contact|ContactList],Timestamp).

send_daily_contacts([],_Timestamp) ->
    ok;
send_daily_contacts([Contact|ContactList], Timestamp) ->
    lager:debug("Contact=~p",[Contact]),
    % lager:debug("Timestamp=~p, time=~p",[Timestamp,Contact#contact.time]),

    %% must handle case where SELCALL addresses are stored, since
    %% these are just integers and cause problems for to_json()
    NewContact = case is_number(Contact#contact.id) of
                     true -> 
                         Contact#contact{id = integer_to_binary(Contact#contact.id)};
                     false ->
                         Contact
                 end,
    Tdiff = Timestamp - NewContact#contact.time,
    case Tdiff < 86400 of %% is less than 24 hrs ??
        true ->
            ContactEJSON = contact:to_json(NewContact),
            ContactMsg = build_response([{event,ale_new_contact}, {data, jsx:encode(ContactEJSON)}]),
            backend_handler ! {data, ContactMsg},
            send_daily_contacts(ContactList, Timestamp);
        false ->
            send_daily_contacts(ContactList, Timestamp)
    end.

websocket_handle({text, Msg}, Req, State) ->
    Decoded = jsx:decode(Msg), 
    {<<"action">>, Action} = lists:keyfind(<<"action">>, 1, Decoded),
    Response = case Action of
                    <<"fnctrl">> ->
                       {{IP, _Port}, _Req2} = cowboy_req:peer(Req),
                       audio_server_proc ! {hmi_addr, IP},
                       build_response([{action, <<"fnctrl">>}, {response,<<"ok">>}]);
                    <<"modemctrl">> ->
                       TxGainResult = case lists:keyfind(<<"txgain">>, 1, Decoded) of
                                          {<<"txgain">>, TxGain} ->
                                              TxGainWord = <<TxGain:32/unsigned-little-integer>>,
                                              {atomic, ok} = radio_db:write_config("default_tx_gain", TxGainWord),
                                              lager:info("wrote default TX gain to DB"),
                                              lager:debug("not setting txgain in HW"),
                                              {txgain, TxGain};
                                          false -> nothing
                                      end,
                       AleTxGainResult = case lists:keyfind(<<"aletxgain">>, 1, Decoded) of
                                             {<<"aletxgain">>, AleTxGain} ->
                                                 AleTxGainWord = <<AleTxGain:32/unsigned-little-integer>>,
                                                 {atomic, ok} = radio_db:write_config("ale_tx_gain", AleTxGainWord),
                                                 lager:info("wrote ALE TX gain to DB"),
                                                 {aletxgain, AleTxGain};
                                             false -> nothing
                                         end,            
                       RxGainResult = case lists:keyfind(<<"rxgain">>, 1, Decoded) of
                                          {<<"rxgain">>, RxGain} ->
                                              RxGainWord = <<RxGain:32/unsigned-little-integer>>,
                                              {atomic, ok} = radio_db:write_config("default_rx_gain", RxGainWord),
                                              lager:info("wrote default RX gain to DB"),     
                                              lager:debug("not setting rxgain in HW"),
                                              {rxgain, RxGain};
                                          false -> nothing
                                      end,            
                       build_response([{action,<<"modemctrl">>}, {response,<<"ok">>}, TxGainResult, AleTxGainResult, RxGainResult]);
                   <<"radioctrl_get">> ->
                       {<<"fband">>, Band} = lists:keyfind(<<"fband">>, 1, Decoded),
                       {<<"freq">>, Freq} = lists:keyfind(<<"freq">>, 1, Decoded),
                       {<<"mode">>, Mode} = lists:keyfind(<<"mode">>, 1, Decoded),
                       {<<"ptt">>, Ptt} = lists:keyfind(<<"ptt">>, 1, Decoded),
                       jsx:encode([{action, <<"radioctrl_get">>}, {response,"ok"},
                                   {fband,Band}, {freq,Freq}, {mode,Mode}, {ptt,Ptt}]);
                   <<"radioctrl_set">> ->
                       FreqResult = case lists:keyfind(<<"freq">>, 1, Decoded) of
                                        {<<"freq">>, Freq} ->
                                            % ok = spawn_radio_control_port_set_freq(Freq),
                                            % ok = spawn_pa_control_port_set_freq(Freq),
                                            FreqCmdType = <<"FA">>,
                                            FreqCmdTerm = <<";">>,
                                            FreqBin = list_to_binary(integer_to_list(Freq)),
                                            FreqCmd = << FreqCmdType/binary, FreqBin/binary, FreqCmdTerm/binary  >>,
                                            message_server_proc ! {cmd, FreqCmd},
                                            ok = ale:current_freq(Freq), %% tell ALE datalink about current freq
                                            {freq, Freq};
                                        false -> nothing
                                    end,
                       ModeResult = case lists:keyfind(<<"mode">>, 1, Decoded) of
                                        {<<"mode">>, Mode} ->
                                            ModeCmdType = <<"MD">>,
                                            ModeCmdTerm = <<";">>,
                                            ModeBin = list_to_binary(integer_to_list(Mode)),
                                            ModeCmd = << ModeCmdType/binary, ModeBin/binary, ModeCmdTerm/binary  >>,
                                            message_server_proc ! {cmd, ModeCmd},
                                            % ok = spawn_radio_control_port_set_mode(Mode),
                                            {mode,Mode};
                                        false -> nothing
                                    end,
                       PttResult = case lists:keyfind(<<"ptt">>, 1, Decoded) of
                                       {<<"ptt">>, Ptt} ->
                                           lager:debug("NOT Set Ptt=~p", [Ptt]),
                                           {ptt,Ptt};
                                       false -> nothing
                                   end,
                       build_response([{action,<<"radioctrl_set">>}, {response,<<"ok">>}, FreqResult,ModeResult,PttResult]);
                   <<"channel_request">> ->
                       RecordResult = case lists:keyfind(<<"number">>, 1, Decoded) of
                                          {<<"number">>, ChanNum} ->
                                              lager:debug("Req channel ~p", [ChanNum]),                
                                              {ok, Record} = radio_db:read_channel(ChanNum),
                                              JSON = jsx:encode(channel:to_json(Record)),
                                              {channel, JSON};
                                          false -> nothing
                                      end,
                       build_response([{action,<<"channel_request">>}, {response,<<"ok">>}, RecordResult]);
                   <<"contact_request">> ->
                       lager:debug("Req contacts..."),
                       ContactList = radio_db:read_all_contacts(),
                       SortedList = lists:keysort(3,ContactList),
                       %% send all contacts!
                       ok = send_daily_contacts(SortedList),
                       %% then send ok
                       build_response([{action,<<"contact_request">>}, {response,<<"ok">>}]);            
                   <<"config">> ->
                        %% client is setting radio configuration parameters
                       {<<"name">>, Name} = lists:keyfind(<<"name">>, 1, Decoded),
                       {<<"value">>, Value} = lists:keyfind(<<"value">>, 1, Decoded),
                       {atomic, ok} = radio_db:write_config(Name,Value),
                       lager:debug("wrote config parameter ~p = ~p to DB", [Name, Value]);
                   Others ->
                       lager:warning("unhandled command: ~p",[Others])
               end,
    {reply, {text, << Response/binary >>}, Req, State, hibernate };

websocket_handle(_Any, Req, State) ->
    {reply, {text, << "whut?">>}, Req, State, hibernate }.

websocket_info({data, Msg}, Req, State) ->
    lager:debug("got data message: ~p",[Msg]),
    {reply, {text, Msg}, Req, State};

websocket_info({bin, Msg}, Req, State) ->
    % lager:debug("got data message: ~p",[Msg]),
    {reply, {binary, Msg}, Req, State};

websocket_info({timeout, _Ref, Msg}, Req, State) ->
    lager:info("client connection timeout..."),
    audio_server_proc ! {hmi_addr, {0,0,0,0}},
    ale:ctrl_disconnect(),
    {reply, {text, Msg}, Req, State};

websocket_info(_Info, Req, State) ->
    lager:debug("websocket info"),
    {ok, Req, State, hibernate}.

websocket_terminate(_Reason, _Req, _State) ->
    lager:info("client socket closed..."),
    audio_server_proc ! {hmi_addr, {0,0,0,0}},
    ale:ctrl_disconnect(),
    ok.

terminate(_Reason, _Req, _State) ->
    ok.
