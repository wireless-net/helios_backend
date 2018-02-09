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

-module(pa_control_port).

-export([open/2,close/0,init/3]).

-export([   set_band/1
            ,get_band/0
            ,set_freq/1
            ,get_freq/0
            ,set_ptt/1
            ,get_ptt/0
            ,set_mode/1
            ,get_mode/0
        ]).

-export([start_link/0]).

start_link() ->
    Pid = open(none,none),
    {ok, Pid}.

open(Device, Rate) ->
    %% for now load the hr50 control port
    spawn_link(?MODULE, init, [lists:concat([code:priv_dir(backend),"/hr50_control_port"]), Device, Rate]).

close() ->
    pa_control_proc ! stop,
    unregister(pa_control_proc).

% read() ->
    % wait_port().

set_band(Band) ->
    BandBin = <<Band:32/unsigned-little-integer>>,
    call_port({set_band, BandBin, size(BandBin)}).

get_band() ->
    {ok, <<Band:32/unsigned-little-integer>>} = call_port({get_band, <<>>, 4}),
    Band.

set_freq(Freq) ->
    FreqBin = <<Freq:32/unsigned-little-integer>>,
    call_port({set_freq, FreqBin, size(FreqBin)}).

get_freq() ->
    {ok, <<Freq:32/unsigned-little-integer>>} = call_port({get_freq, <<>>, 4}),
    Freq.

set_ptt(Ptt) ->
    PttBin = <<Ptt:32/unsigned-little-integer>>,
    call_port({set_ptt, PttBin, size(PttBin)}).

get_ptt() ->
    {ok, <<Ptt:32/unsigned-little-integer>>} = call_port({get_ptt, <<>>, 4}),
    Ptt.

set_mode(Mode) ->
    ModeBin = <<Mode:32/unsigned-little-integer>>,
    call_port({set_mode, ModeBin, size(ModeBin)}).

get_mode() ->
    {ok, <<Ptt:32/unsigned-little-integer>>} = call_port({get_mode, <<>>, 4}),
    Ptt.

call_port(Msg) ->
    pa_control_proc ! {call, self(), Msg},
    receive
        { pa_control_proc, Result } ->
            Result
    end.

init(ExtPrg, _Device, _Rate) ->
    register(pa_control_proc, self()),
    process_flag(trap_exit, true),
    % Port = open_port({spawn_executable, ExtPrg}, [{args, [Device, integer_to_list(Rate)]}, {packet, 2}, use_stdio,binary]),
    Port = open_port({spawn_executable, ExtPrg}, [{args, []}, {packet, 2}, use_stdio, binary, exit_status]),
    loop(Port).

%% The pa_control_proc process loop
loop(Port) ->
    receive
        {call, Caller, Msg} ->
            lager:debug("got call, calling port..."),
            Port ! {self(), {command, encode(Msg)}},
            lager:debug("waiting for result"),
            receive
                %% if event comes in, it stays queued until we loop (because it won't match here)
                {Port, {data, <<0:16/unsigned-little-integer,Data/binary>>}} ->
                 % {data,<<0,0,253,182,200,189>>}
                    lager:debug("got OK ~p",[Data]),
                    Caller ! {pa_control_proc, {ok, Data}};
                {Port, {data, <<65535:16/unsigned-little-integer,_Arg/binary>>}} ->
                    lager:debug("got ERR"),
                    Caller ! {pa_control_proc, error};
                {Port, Unhandled} ->
                    lager:info("got unhandled response: ~p",[Unhandled])
	        after 5000 ->
		      erlang:error(port_timeout)
            end,
            loop(Port);
        stop ->
            lager:info("got stop"),
            Port ! {self(), close},
            receive
                {Port, closed} ->
                    exit(normal)
            end;
        shutdown ->
            lager:info("got shutdown"),
            Port ! {self(), close},
            receive
                {Port, closed} ->
                    exit(normal)
            end;            
        {'EXIT', _Port, Reason} ->
            lager:info("Port terminated for reason: ~p", [Reason]),
            {os_pid, OsPid} = erlang:port_info(Port, os_pid),
            os:cmd(io_lib:format("kill -9 ~p", [OsPid])),
            Port ! {self(), close},
            exit(normal);
        Unhandled ->
            lager:error("Port got unhandled message ~p", [Unhandled]),
            {os_pid, OsPid} = erlang:port_info(Port, os_pid),
            os:cmd(io_lib:format("kill -9 ~p", [OsPid])),
            Port ! {self(), close},
            exit(port_terminated)        
    end.

%% encode takes atoms and converts to corresponding op-code
encode({set_band, Data, Len}) ->
    [<<1:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>>, <<Data/binary>>];
encode({get_band, _Data, Len}) ->
    [<<2:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>> ];
encode({set_freq, Data, Len}) ->
    [<<3:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>>, <<Data/binary>>];
encode({get_freq, _Data, Len}) ->
    [<<4:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>> ];
encode({set_ptt, Data, Len}) ->
    [<<5:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>>, <<Data/binary>>];
encode({get_ptt, _Data, Len}) ->
    [<<6:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>> ];
encode({set_mode, Data, Len}) ->
    [<<7:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>>, <<Data/binary>>];
encode({get_mode, _Data, Len}) ->
    [<<8:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>> ].