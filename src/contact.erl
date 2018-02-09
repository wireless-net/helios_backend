%% 
%% This module is augmented by rec2json at compile time with functions for converting stat records to and from Erlang-JSON compatible formats.
-module(contact).

-include("modem.hrl").

-compile([{parse_transform, rec2json}]).

-export([test/0]).

% -record(contact, {	
% 		id 			:: binary(),
% 		timestamp	:: integer(),
% 		frequency 	:: integer(),
% 		ber 		:: integer(),
% 		name 		:: binary(),
% 		coordinates :: binary(),
% 		power 		:: integer(),
% 		radio 		:: binary(),
% 		controller 	:: binary(),
% 		antenna 	:: binary()
% 	}).

test() ->
	Contact = 	#contact{	id 			= <<"KD6DRS">>,
							time		= 0,
							channel		= 0,
							frequency 	= 5357000,
							ber 		= 0,
							sinad 		= 31,
							name 		= <<"unknown">>,
							coordinates = <<"unknown">>,
							power 		= 0,
							radio 		= <<"unknown">>,
							controller 	= <<"unknown">>,
							antenna 	= <<"unknown">>
				},
	io:format("Record in: ~p~n", [Contact]),
	EJSON = contact:to_json(Contact),
	JSON = jsx:encode(EJSON),
	io:format("JSON=~p~n",[JSON]),
	EJSONo = jsx:decode(JSON),
	{ok, Contact} = contact:from_json(EJSONo),
	io:format("Record out = ~p~n",[Contact]).
