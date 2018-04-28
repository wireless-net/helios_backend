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

start_link() ->
    Pid = spawn_link(?MODULE, init, [?MESSAGE_PORT]),
    {ok, Pid}.

init(UdpPort) ->
    {ok, Socket} = gen_udp:open(UdpPort, [binary, {active, true}, {reuseaddr, true},{ip, loopback}]),
    lager:info("message server opened socket: ~p",[Socket]),
    register(message_server_proc, self()),
    process_flag(trap_exit, true),
    loop(Socket).

send_words(<<ALEWord:32/unsigned-little-integer, Rest/binary>>) ->
    % lager:info("ALE WORD: ~.16b~n", [ALEWord]),
    ale:rx(ALEWord),
    send_words(Rest);
send_words(<<>>) ->
    ok.

%% The frontend_port_proc process loop
loop(Socket) ->
    % inet:setopts(Socket, [{active, once}]),
    receive
        {udp, Socket, _Host, _Port, Bin} ->
            % lager:info("server received:~p~n",[Bin]),
            % <<Freq:32/unsigned-little-integer, RestWithLen/binary>> = Bin,
            % <<Len:32/unsigned-little-integer, Rest/binary>> = RestWithLen,
            % lager:info("Freq=~p Len=~p",[Freq,Len]),
            case whereis(ale) of
                undefined -> lager:warning("ALE datalink is not running");
                _ ->
                    send_words(Bin)
            end,             
            % gen_udp:send(Socket, Host, Socket, Bin),
            loop(Socket);
        {cmd, MsgBin} ->
            %%lager:debug("sending message: ~p", [MsgBin]),
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