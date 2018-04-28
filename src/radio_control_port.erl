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

-module(radio_control_port).

-export([open/2,close/0,init/4]).

-export([   set_band/1
            ,get_band/0
            ,set_freq/1
            ,get_freq/0
            % ,set_ptt/1
            % ,get_ptt/0
            ,set_mode/1
            ,get_mode/0
            ,tx/1
            ,tuner/1
        ]).

-export([start_link/0]).

start_link() ->
    Pid = open(none,none),
    {ok, Pid}.

open(Device, Rate) ->
    %% load the control port
    EnabledRadioPort = try radio_db:read_config(radio_control_port) of
                        EnabledRadio -> EnabledRadio
                    catch
                        _:_ -> []
                    end,    
    case EnabledRadioPort of
        kx3_control_port ->
            spawn_link(?MODULE, init, [op, lists:concat([code:priv_dir(helios_backend),"/kx3_control_port"]), Device, Rate]);
        _ ->
            lager:warning("No supported Radio control port is configured, Radio control disabled"),
            spawn_link(?MODULE, init, [nop, none, none, none])
        %% ADD OTHER RADIO TYPES HERE
        %% IF CALLED WITH UNSUPPORTED, IT BECOMES A NOP
    end.

close() ->
    radio_control_proc ! stop,
    unregister(radio_control_proc).

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

% set_ptt(Ptt) ->
%     PttBin = <<Ptt:32/unsigned-little-integer>>,
%     call_port({set_ptt, PttBin, size(PttBin)}).

% get_ptt() ->
%     {ok, <<Ptt:32/unsigned-little-integer>>} = call_port({get_ptt, <<>>, 4}),
%     Ptt.

set_mode(Mode) ->
    ModeBin = <<Mode:32/unsigned-little-integer>>,
    call_port({set_mode, ModeBin, size(ModeBin)}).

get_mode() ->
    {ok, <<Ptt:32/unsigned-little-integer>>} = call_port({get_mode, <<>>, 4}),
    Ptt.

tx(OnOff) ->
    radio_control_proc ! {tx, self(), OnOff},
    receive
        { radio_control_proc, Result } ->
            Result
    end.

tuner(Mode) ->
    radio_control_proc ! {tuner, self(), Mode},
    receive
        { radio_control_proc, Result } ->
            Result
    end.

call_port(Msg) ->
    radio_control_proc ! {call, self(), Msg},
    receive
        { radio_control_proc, Result } ->
            Result
    end.

init(nop, _, _, _) ->
    register(radio_control_proc, self()),
    process_flag(trap_exit, true),
    loop(nop);   
init(op, ExtPrg, _Device, _Rate) ->
    register(radio_control_proc, self()),
    process_flag(trap_exit, true),

    %% init gpio for RF switch
    Rfswctl = gpio:init(10, out),

    % init gpio for PTT control
    Pttctl = gpio:init(2, out),

    %% XXX XXX FIXME: move tuner control to its own port!!!
    %% init gpio for Tuner contol
    Tunerctl = gpio:init(5, out),

    %% Ensure PTT is off
    ok = gpio:write(Pttctl, 0),
    
    %% Ensure RF switch is set to RX
    ok = gpio:write(Rfswctl, 0),

    %% Set tuner to scan mode
    %% For SG230, this means toggling the reset line.
    ok = gpio:write(Tunerctl, 1),
    timer:sleep(100),
    ok = gpio:write(Tunerctl, 0),
    
    % Port = open_port({spawn_executable, ExtPrg}, [{args, [Device, integer_to_list(Rate)]}, {packet, 2}, use_stdio,binary]),
    Port = open_port({spawn_executable, ExtPrg}, [{args, []}, {packet, 2}, use_stdio, binary, exit_status]),
    loop({Port, Rfswctl, Pttctl, Tunerctl}).

%% The radio_control_proc process loop (No-OP version, when no hardware connected)
loop(nop) ->
    receive
        {call, Caller, _Msg} ->
            Caller ! {radio_control_proc, {ok, nop}},
            loop(nop);
        {tx, Caller, _} ->
            Caller ! {radio_control_proc, ok},           
            loop(nop);
        {tuner, Caller, _} ->
            Caller ! {radio_control_proc, ok},                 
            loop(nop);            
        stop ->
            exit(normal);
        shutdown ->
            exit(normal);
        {'EXIT', _Port, Reason} ->
            lager:info("Port terminated for reason: ~p", [Reason]),
            exit(normal);
        Unhandled ->
            lager:error("Port got unhandled message ~p", [Unhandled]),
            exit(port_terminated)        
    end;    
%% Normal version, with hardware
loop({Port, Rfswctl, Pttctl, Tunerctl}) ->
    receive
        {call, Caller, Msg} ->
            % lager:debug("got call, calling port..."),
            Port ! {self(), {command, encode(Msg)}},
            % lager:debug("waiting for result"),
            receive
                %% if event comes in, it stays queued until we loop (because it won't match here)
                {Port, {data, <<0:16/unsigned-little-integer,Data/binary>>}} ->
                %  {data,<<0,0,253,182,200,189>>}
                    % lager:debug("got OK ~p",[Data]),
                    Caller ! {radio_control_proc, {ok, Data}};
                {Port, {data, <<65535:16/unsigned-little-integer,_Arg/binary>>}} ->
                    lager:debug("got ERR"),
                    Caller ! {radio_control_proc, error};
                {Port, Unhandled} ->
                    lager:info("got unhandled response: ~p",[Unhandled])
	        after 5000 ->
		      erlang:error(port_timeout)
            end,
            loop({Port, Rfswctl, Pttctl, Tunerctl});
        {tx, Caller, on} ->
            %% set RF switch to transmitter
            ok = gpio:write(Rfswctl, 1),
            %% set transmitter PTT to ON
            ok = gpio:write(Pttctl, 1),        
            Caller ! {radio_control_proc, {ok, on}},           
            loop({Port, Rfswctl, Pttctl, Tunerctl});
        {tx, Caller, off} ->
            %% Ensure PTT is off
            ok = gpio:write(Pttctl, 0),
            %% Ensure RF switch is set to RX
            ok = gpio:write(Rfswctl, 0),
            %% XXX FIXME: get this outta here!!!
            %% Set tuner to scan mode
            %% For SG230, this means toggling the reset line.
            ok = gpio:write(Tunerctl, 1),
            timer:sleep(100),
            ok = gpio:write(Tunerctl, 0),
            Caller ! {radio_control_proc, {ok, off}},                 
            loop({Port, Rfswctl, Pttctl, Tunerctl});
        {tuner, Caller, scan} ->
            %% XXX FIXME: get this outta here!!!
            %% Set tuner to scan mode
            %% For SG230, this means toggling the reset line.
            ok = gpio:write(Tunerctl, 1),
            timer:sleep(100),
            ok = gpio:write(Tunerctl, 0),
            Caller ! {radio_control_proc, {ok,scan}},           
            loop({Port, Rfswctl, Pttctl, Tunerctl});
        {tuner, Caller, tuned} ->
            %% XXX FIXME: get this outta here!!!
            %% for SG230, nothing to do
            Caller ! {radio_control_proc, {ok,tuned}},                 
            loop({Port, Rfswctl, Pttctl, Tunerctl});            
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