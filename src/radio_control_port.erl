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

-include("radio.hrl").

-export([open/0,close/0,init/3]).

-export([   set_band/1
            ,get_band/0
            ,set_freq/1
            ,get_freq/0
            ,set_chan/1
            ,get_chan/0
            ,set_ptt/1
            ,get_ptt/0
            ,set_mode/1
            ,get_mode/0
            ,rf_switch/1
            ,tuner/1
            ,set_control_port/1
            , transmit_control/2
            , set_transmit_control/1
        , tune_transmitter/2
        , transmitter_mode/2
        
            
            
        % , set_tuner_control/1
            
        ]).

-export([start_link/0]).

%% helper to make it easier and enforce only valid values
set_control_port(kx3_control_port) ->
    radio_db:write_config(radio_control_port, kx3_control_port);
set_control_port(codan_control_port) ->
    radio_db:write_config(radio_control_port, codan_control_port);    
set_control_port(none) ->
    radio_db:write_config(radio_control_port, none).

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

%%
%% Helpers for setting transmit, pa, and tuner control
%% makes it easier and prevents invalid values....
%%
set_transmit_control(external) ->
    radio_db:write_config(transmit_control, external);
set_transmit_control(internal) ->
    radio_db:write_config(transmit_control, internal);
set_transmit_control(none) ->
    radio_db:write_config(transmit_control, none).

% set_tuner_control(external) ->
%     radio_db:write_config(tuner_control, external);
% set_tuner_control(internal) ->
%     radio_db:write_config(tuner_control, internal);
% set_tuner_control(none) ->
%     radio_db:write_config(tuner_control, none).


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

%%
%% Tuner control handling
%%
% tuner_control(none, Mode) ->
%     %% do nothing, no radio to control
%     {ok, Mode};
% tuner_control(external, Mode) ->
%     radio_control_port:tuner(Mode).


start_link() ->
    Pid = open(),
    {ok, Pid}.

open() ->
    %% load the control port
    EnabledRadioPort = try radio_db:read_config(radio_control_port) of
                        EnabledRadio -> EnabledRadio
                    catch
                        _:_ -> []
                    end,    
    case EnabledRadioPort of
        kx3_control_port ->
            spawn_link(?MODULE, init, [op, lists:concat([code:priv_dir(helios_backend),"/kx3_control_port"]), []]);
        codan_control_port ->
            %% FIXME: just hardcoding the can interface name for now
            spawn_link(?MODULE, init, [op, lists:concat([code:priv_dir(helios_backend),"/codan_control_port"]), ["slcan0"]]);
        _ ->
            lager:warning("No supported Radio control port is configured, Radio control disabled"),
            spawn_link(?MODULE, init, [nop, none, none])
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

set_chan(Chan) ->
    ChanBin = <<Chan:32/unsigned-little-integer>>,
    call_port({set_chan, ChanBin, size(ChanBin)}).

get_chan() ->
    {ok, <<Chan:32/unsigned-little-integer>>} = call_port({get_chan, <<>>, 4}),
    Chan.

set_ptt(true) ->
    set_ptt(on);
set_ptt(false) ->
    set_ptt(off);
set_ptt(OnOff) ->
    radio_control_proc ! {ptt, self(), OnOff},
    receive
        { radio_control_proc, Result } ->
            Result
    end.    

% set_ptt(Ptt) ->
%     PttBin = <<Ptt:32/unsigned-little-integer>>,
%     call_port({set_ptt, PttBin, size(PttBin)}).

get_ptt() ->
    {ok, <<Ptt:32/unsigned-little-integer>>} = call_port({get_ptt, <<>>, 4}),
    Ptt.

set_mode(Mode) ->
    ModeBin = <<Mode:32/unsigned-little-integer>>,
    call_port({set_mode, ModeBin, size(ModeBin)}).

get_mode() ->
    {ok, <<Ptt:32/unsigned-little-integer>>} = call_port({get_mode, <<>>, 4}),
    Ptt.

rf_switch(true) ->
    rf_switch(on);
rf_switch(false) ->
    rf_switch(off);
rf_switch(1) ->
    rf_switch(on);
rf_switch(0) ->
    rf_switch(off);
rf_switch(OnOff) ->
    radio_control_proc ! {rf_switch, self(), OnOff},
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

init(nop, _, _) ->
    lager:info("starting in nop mode"),
    register(radio_control_proc, self()),
    process_flag(trap_exit, true),
    loop(nop);   
init(op, ExtPrg, Args) ->
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
    Port = open_port({spawn_executable, ExtPrg}, [{args, Args}, {packet, 2}, use_stdio, binary, exit_status]),
    loop({Port, Rfswctl, Pttctl, Tunerctl}).

%% The radio_control_proc process loop (No-OP version, when no hardware connected)
loop(nop) ->
    receive
        {call, Caller, _Msg} ->
            Caller ! {radio_control_proc, {ok, nop}},
            loop(nop);
        {rf_switch, Caller, Val} ->
            Caller ! {radio_control_proc, {ok,Val}},           
            loop(nop);
        {ptt, Caller, Val} ->
            Caller ! {radio_control_proc, {ok,Val}},
            loop(nop);
        {tuner, Caller, Val} ->
            Caller ! {radio_control_proc, {ok, Val}},                 
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
            lager:debug("got call, calling port... ~p", [Msg]),
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
        {Port, {data, <<1:16/unsigned-little-integer,Data/binary>>}} ->
            <<PttState:32/unsigned-little-integer>> = Data,
            %% set RF switch accordingly
            lager:debug("New PTT State ~p", [PttState]),
            ok = gpio:write(Rfswctl, PttState),
            loop({Port, Rfswctl, Pttctl, Tunerctl});
        {ptt, Caller, on} ->
            %% set transmitter PTT to ON
            ok = gpio:write(Pttctl, 1),        

            Caller ! {radio_control_proc, {ok, on}},           
            loop({Port, Rfswctl, Pttctl, Tunerctl});
        {ptt, Caller, off} ->
            %% Ensure PTT is off
            ok = gpio:write(Pttctl, 0),
            Caller ! {radio_control_proc, {ok, off}},                 
            loop({Port, Rfswctl, Pttctl, Tunerctl});
        {rf_switch, Caller, on} ->
            %% set RF switch to transmitter
            ok = gpio:write(Rfswctl, 1),

            Caller ! {radio_control_proc, {ok, on}},           
            loop({Port, Rfswctl, Pttctl, Tunerctl});
        {rf_switch, Caller, off} ->
            %% set RF switch to RX
            ok = gpio:write(Rfswctl, 0),

            %% XXX FIXME: get this outta here!!!
            %% Set tuner to scan mode
            %% For SG230, this means toggling the reset line.
            % ok = gpio:write(Tunerctl, 1),
            % timer:sleep(100),
            % ok = gpio:write(Tunerctl, 0),
            Caller ! {radio_control_proc, {ok, off}},                 
            loop({Port, Rfswctl, Pttctl, Tunerctl});
        {tuner, Caller, scan} ->
            %% XXX FIXME: get this outta here!!!
            %% Set tuner to scan mode
            %% For SG230, this means toggling the reset line.
            % ok = gpio:write(Tunerctl, 1),
            % timer:sleep(100),
            % ok = gpio:write(Tunerctl, 0),
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
    [<<8:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>> ];
encode({set_chan, Data, Len}) ->
    [<<9:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>>, <<Data/binary>>];
encode({get_chan, _Data, Len}) ->
    [<<10:16/unsigned-little-integer>>, <<Len:16/unsigned-little-integer>> ].
    