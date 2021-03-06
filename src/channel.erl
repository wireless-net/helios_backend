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

%% 
%% This module is augmented by rec2json at compile time with functions for converting stat records to and from Erlang-JSON compatible formats.
-module(channel).

-include("radio.hrl").

-compile([{parse_transform, rec2json}]).

-export([test/0]).

test() ->
	Channel = 	#channel{	id = 0, 
							frequency = 5357000,
							fband = 3,
							sideband = <<"USB">>,
							comm_use = <<"VOICE/DATA">>,
							description = <<"International">>,
							net_name = <<"HFL/HFN">>,
							sounding_status = <<"Manual/Attended sounding">>
				},
	io:format("Record in: ~p~n", [Channel]),
	EJSON = channel:to_json(Channel),
	JSON = jsx:encode(EJSON),
	io:format("JSON=~p~n",[JSON]),
	EJSONo = jsx:decode(JSON),
	{ok, Channel} = channel:from_json(EJSONo),
	io:format("Record out = ~p~n",[Channel]).
