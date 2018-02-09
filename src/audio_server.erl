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

-module(audio_server).

-export([init/1]).

-export([start_link/0]).

-define(RX_AUDIO_PORT, 62345).
-define(TX_AUDIO_PORT, 64321). %% IMPLEMENT ME !!

start_link() ->
    Pid = spawn_link(?MODULE, init, [?RX_AUDIO_PORT]),
    {ok, Pid}.

init(UdpPort) ->
    {ok, Socket} = gen_udp:open(UdpPort, [binary, {active, true}, {reuseaddr, true},{ip, {0,0,0,0}}]),
    lager:info("audio server opened socket: ~p",[Socket]),
    register(audio_server_proc, self()),
    process_flag(trap_exit, true),
    loop(Socket, {0,0,0,0}). %% init null HMI address

send_to_hmi(_Socket, {0,0,0,0}, _Port, _Data) ->
    %% we don't have a valid HMI address, dump Data on the floor
    ok;
send_to_hmi(Socket, HmiAddr, Port, Data) ->
    gen_udp:send(Socket, HmiAddr, Port, Data).

loop(Socket, HmiAddr) ->
    % inet:setopts(Socket, [{active, once}]),
    receive
        {udp, Socket, _Host, _Port, Bin} ->
            %% if this fails, we just crash
            ok = send_to_hmi(Socket, HmiAddr, 12346, Bin), %% XXX FIXME MAKE PORT CONFIGUREABLE
            loop(Socket, HmiAddr);
        {hmi_addr, NewHmiAddr} ->
            lager:info("HMI Address Updated: ~p", [NewHmiAddr]),
            loop(Socket, NewHmiAddr);
        shutdown ->
            lager:info("got shutdown"),
            exit(normal);
        {'EXIT', _Port, Reason} ->
            lager:info("audio server terminated for reason: ~p", [Reason]),
            exit(normal);
        Unhandled ->
            lager:error("audio server got unhandled message ~p", [Unhandled]),
            loop(Socket, HmiAddr)
    end.