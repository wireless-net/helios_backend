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

-module(message_server).

-export([init/1]).

-export([start_link/0]).

-define(MESSAGE_PORT,   12345).
-define(CMD_PORT,       54321).

-include("protocols.hrl").

start_link() ->
    Pid = spawn_link(?MODULE, init, [?MESSAGE_PORT]),
    {ok, Pid}.

init(UdpPort) ->
    {ok, Socket} = gen_udp:open(UdpPort, [binary, {active, true}, {reuseaddr, true},{ip, loopback}]),
    lager:info("message server opened socket: ~p",[Socket]),
    register(message_server_proc, self()),
    process_flag(trap_exit, true),
    loop(Socket).

%% FIXME: get rid of this and just send ALE servie a whole message in a single shot (once it's updated)
% send_words(Service, <<16#40000000:32/unsigned-little-integer, Rest/binary>>) ->
    % send_words(Service, Rest);
send_words(Service, <<Word:32/unsigned-little-integer, Rest/binary>>) ->
    Service:rx(Word),
    send_words(Service,Rest);
send_words(_Service,<<>>) ->
    ok.

relay_message(<<16#40000000:32/unsigned-little-integer, _Rest/binary>>) ->
    %% FIXME!!!
    ale:tx_complete(),
    hecate:tx_complete();
relay_message(<<?PROTOCOL_ALE_2G:32/unsigned-little-integer, Rest/binary>>) ->
    send_words(ale,Rest);
relay_message(<<?PROTOCOL_CCIR_493_4:32/unsigned-little-integer, Rest/binary>>) ->
    hecate:rx(Rest);
relay_message(<<?PROTOCOL_REVERTIVE_DET:32/unsigned-little-integer, Rest/binary>>) ->
    hecate:rx_revertive(Rest);
relay_message(<<Other:32/unsigned-little-integer, _Rest/binary>>) ->
    ale:tx_complete(), %% just in case!!
    hecate:tx_complete(),
    lager:error("unknown message protocol: ~p",[Other]).

%% The frontend_port_proc process loop
loop(Socket) ->
    % inet:setopts(Socket, [{active, once}]),
    receive
        {udp, Socket, _Host, _Port, Bin} ->
            case whereis(ale) of
                undefined -> lager:warning("ALE datalink is not running");
                _ ->
                    relay_message(Bin)
            end,             
            % gen_udp:send(Socket, Host, Socket, Bin),
            loop(Socket);
        {cmd, MsgBin} ->
            ok = gen_udp:send(Socket, {127,0,0,1}, ?CMD_PORT, MsgBin),
            loop(Socket);
        shutdown ->
            lager:info("got shutdown"),
            exit(normal);
        {'EXIT', _Port, Reason} ->
            lager:info("Message server terminated for reason: ~p", [Reason]),
            exit(normal);
        Unhandled ->
            lager:error("Message server got unhandled message ~p", [Unhandled]),
            loop(Socket)
    end.
