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
