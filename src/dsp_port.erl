%% Copyright (c) 2018  Devin Butterfield
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

-module(dsp_port).

-export([open/0,close/0,init/1]).
-export([start_link/0]).

start_link() ->
    Pid = open(),
    {ok, Pid}.

open() ->
    % spawn_link(?MODULE, init, [lists:concat([code:priv_dir(helios_backend),"/dsp.py"])]).
    spawn_link(?MODULE, init, ["/opt/k6drs/gr-k6drs/examples/dsp.py"]).

close() ->
    dsp_proc ! stop,
    unregister(dsp_proc).

% call_port(Msg) ->
%     dsp_proc ! {call, self(), Msg},
%     receive
%         { dsp_proc, Result } ->
%             Result
%     end.

init(DspScript) ->
    register(dsp_proc, self()),
    process_flag(trap_exit, true),
    Port = open_port({spawn_executable, "/opt/local/bin/python"}, [{args, [DspScript]}, {packet, 2}, use_stdio, binary, exit_status]),
    loop(Port).

%% The dsp_proc process loop
loop(Port) ->
    receive
        {Port, {data, <<1:16/unsigned-little-integer,Data/binary>>}} ->
            lager:info("dsp_port: ~p",[Data]),

        % {call, Caller, Msg} ->
        %     lager:debug("got call, calling port..."),
        %     Port ! {self(), {command, encode(Msg)}},
        %     lager:debug("waiting for result"),
        %     receive
        %         %% if event comes in, it stays queued until we loop (because it won't match here)
        %         {Port, {data, <<0:16/unsigned-little-integer,Data/binary>>}} ->
        %             lager:debug("got OK ~p",[Data]),
        %             Caller ! {dsp_proc, {ok, Data}};
        %         {Port, {data, <<65535:16/unsigned-little-integer,_Arg/binary>>}} ->
        %             lager:debug("got ERR"),
        %             Caller ! {dsp_proc, error};
        %         {Port, Unhandled} ->
        %             lager:info("got unhandled response: ~p",[Unhandled])
	       %  after 5000 ->
		      % erlang:error(port_timeout)
        %     end,
            loop(Port);
        {Port, {data, <<2:16/unsigned-little-integer,Data/binary>>}} ->
            %%% XXX FIXME store this data and make available by command
            lager:info("dsp_port: ~p",[Data]),
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
            lager:warning("Port got unhandled message ~p", [Unhandled]),
            % {os_pid, OsPid} = erlang:port_info(Port, os_pid),
            % os:cmd(io_lib:format("kill -9 ~p", [OsPid])),
            % Port ! {self(), close},
            % exit(port_terminated)   
            loop(Port)
    end.