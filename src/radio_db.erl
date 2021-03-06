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

-module(radio_db).

-export([	create_database/1
			,write_config/2
			,read_config/1
			,write_channel/8
			,read_channel/1
			,write_hflink_channels/0
			,write_contact/1
			,read_contact/1
			,write_alqa/1
			,read_alqa/1
			,read_all_alqas/0
			,channel_count/0
			,read_all_contacts/0
			,find_channel/1
			,find_auto_channels/0
			,write_self_address/6
			,read_self_address/1
			,write_other_address/6
			,read_other_address/1
		]).

-include("radio.hrl").

% Must first do this:
% erl -mnesia dir "'$PWD/db'" -sname backend -setcookie k6drs -pa $PWD/ebin -pa $PWD/deps/*/ebin -config $PWD/priv/app.config
% radio_db:create_database("K6DRS").

create_database(OwnAddr) ->
	ok = mnesia:create_schema([node()]),
	ok = mnesia:start(),
    {atomic, ok} = mnesia:create_table(config, [{disc_copies, [node()]},{attributes, record_info(fields, config)}]),
    {atomic, ok} = mnesia:create_table(channel, [{disc_copies, [node()]},{attributes, record_info(fields, channel)}]),
    {atomic, ok} = mnesia:create_table(contact, [{disc_copies, [node()]},{attributes, record_info(fields, contact)}]),
    {atomic, ok} = mnesia:create_table(alqa, [{disc_copies, [node()]},{attributes, record_info(fields, alqa)}]),
	{atomic, ok} = mnesia:create_table(self_address, [{disc_copies, [node()]},{attributes, record_info(fields, self_address)}]),
	{atomic, ok} = mnesia:create_table(other_address, [{disc_copies, [node()]},{attributes, record_info(fields, other_address)}]),
	{atomic, ok} = radio_db:write_config(id, OwnAddr),
	{atomic, ok} = radio_db:write_hflink_channels(),
	%% OWN: 	
	{atomic, ok} = radio_db:write_self_address(OwnAddr, own, none, [], [all], default),

	{atomic, ok} = radio_db:write_self_address("?@?", own, none, [], [all], default),	
	%% NULL:	
	{atomic, ok} = radio_db:write_self_address("", null, none, [], [], default), 
	%% HFR:		
	{atomic, ok} = radio_db:write_self_address("HFR", net, OwnAddr, [1], [all], default),
	%% HFN:		
	{atomic, ok} = radio_db:write_self_address("HFN", net, OwnAddr, [1], [all], default),
	%% HFL:		
	{atomic, ok} = radio_db:write_self_address("HFL", net, OwnAddr, [1], [all], default),
	%% GLOBALL:	
	{atomic, ok} = radio_db:write_self_address("@?", global_allcall, OwnAddr, [], [all], default),
	%% GLOBANY:	
	{atomic, ok} = radio_db:write_self_address("@@?", global_anycall, OwnAddr, [random], [all], default),
	{atomic, ok} = radio_db:write_config(current_freq, 5357000),
	{atomic, ok} = radio_db:write_config(hflink_reporting, false),
	{atomic, ok} = radio_db:write_config(radio_control_port, none),
	{atomic, ok} = radio_db:write_config(transmit_control, none),
    % {atomic, ok} = radio_db:write_config(tuner_control, none),
    {atomic, ok} = radio_db:write_config(pa_control, none),
	ok.

write_config(Name, Value) ->
	Config = #config{name = Name, value = Value},
    Fun = fun() ->
		mnesia:write(Config)
	end,
    mnesia:transaction(Fun).

read_config(Name) ->
	Fun = fun() ->
		mnesia:read({config, Name})
	end,
	{atomic,[{config, _, Value}]} = mnesia:transaction(Fun),
	Value.

write_channel(Id, Frequency, Band, Sideband, CommUse, Description, NetName, SoundingStatus) ->
	Channel = 	#channel{	id = Id,
							frequency = Frequency,
							fband = Band,
							sideband = Sideband,
							comm_use = CommUse,
							description = Description,
							net_name = NetName,
							sounding_status = SoundingStatus
				},
    Fun = fun() ->
		mnesia:write(Channel)
	end,
    mnesia:transaction(Fun).

read_channel(Id) ->
	Fun = fun() ->
		mnesia:read({channel, Id})
	end,
	case mnesia:transaction(Fun) of
		{atomic,[Record]} ->
			{ok, Record};
		{atomic, []} ->
			NullChan = #channel{	id = Id,
							frequency = 3596000,
							fband = 2,
							sideband = <<"USB">>,
							comm_use = <<"--">>,
							description = <<"--">>,
							net_name = <<"--">>,
							sounding_status = <<"--">> },
			{ok, NullChan}
	end.

find_channel(Freq) ->
    Constraint = 
         fun(Chan, Acc) when Chan#channel.frequency == Freq ->
                [Chan | Acc];
            (_, Acc) ->
                Acc
         end,
    Find = fun() -> mnesia:foldl(Constraint, [], channel) end,
    {atomic, Channels} = mnesia:transaction(Find),
    Channels.

find_auto_channels() ->
    Constraint = 
         fun(Chan, Acc) when Chan#channel.sounding_status == <<"Auto">> ->
                [Chan | Acc];
            (_, Acc) ->
                Acc
         end,
    Find = fun() -> mnesia:foldl(Constraint, [], channel) end,
    {atomic, Channels} = mnesia:transaction(Find),
    Channels.

write_hflink_channels() ->
	write_channel(1,	1843000,	0, <<"USB">>,	<<"DATA/VOICE">>, 	<<"International">>, 			<<"01AHFN">>,	<<"Auto">>),
	write_channel(2,	1996000,	0, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"01BHFL">>,	<<"Attended">>),
	write_channel(3,	3596000,	1, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"03AHFN">>,	<<"Auto">>),
	write_channel(4,	3791000,	1, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"03BHFL">>, 	<<"Attended">>),
	write_channel(5,	3996000,	1, <<"USB">>,	<<"VOICE">>, 		<<"Regional">>, 				<<"03CHFL">>, 	<<"Attended">>),
	write_channel(6,	5357000,	2, <<"USB">>,	<<"DATA/VOICE">>, 	<<"Primary Intl.">>, 			<<"05AHFL">>, 	<<"Auto">>),
	write_channel(7,	5360000,	2, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"05BHFL">>, 	<<"Attended">>),
	write_channel(8,	5371500,	2, <<"USB">>,	<<"VOICE">>, 		<<"Regional">>, 				<<"05CHFL">>, 	<<"Attended">>),
	write_channel(9,	7102000,	3, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"07AHFN">>,	<<"Auto">>),
	write_channel(10,	7185500,	3, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"07BHFL">>, 	<<"Attended">>),
	write_channel(11,	7296000,	3, <<"USB">>,	<<"VOICE">>,		<<"Regional">>, 				<<"07CHFL">>, 	<<"Attended">>),
	write_channel(12,	10145500,	4, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"10AHFN">>,	<<"Auto">>),
	write_channel(13,	14109000,	5, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"14AHFN">>,	<<"Auto">>),
	write_channel(14,	14346000,	5, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"14BHFL">>, 	<<"Attended">>),
	write_channel(15,	18106000,	6, <<"USB">>,	<<"DATA">>,			<<"Primary Intl.">>, 			<<"18AHFN">>,	<<"Auto">>),
	write_channel(16,	18117500,	6, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"18BHFL">>, 	<<"Attended">>),
	write_channel(17,	21096000,	7, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"21AHFN">>,	<<"Auto">>),
	write_channel(18,	21432500,	7, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"21BHFL">>, 	<<"Attended">>),
	write_channel(19,	3845000,	1, <<"USB">>,	<<"VOICE">>, 		<<"North America">>, 			<<"HFS3C">>, 	<<"Attended">>),
	write_channel(20,	5403500,	2, <<"USB">>,	<<"VOICE">>, 		<<"North America">>, 			<<"HFS5A">>, 	<<"Attended">>),
	write_channel(21,	7195000,	3, <<"USB">>,	<<"VOICE">>, 		<<"North America">>, 			<<"HFS7C">>, 	<<"Attended">>),
	write_channel(22,	10144000,	4, <<"USB">>,	<<"VOICE">>, 		<<"North America">>, 			<<"HFS10B">>, 	<<"Attended">>).

channel_count() ->
	mnesia:table_info(channel, size).

%% if successful, returns {atomic, ok}
write_contact(Contact) ->
    Fun = fun() ->
		mnesia:write(Contact)
	end,
    mnesia:transaction(Fun).

read_contact(Id) ->
	Fun = fun() ->
		mnesia:read({contact, Id})
	end,
	case mnesia:transaction(Fun) of
		{atomic,[Record]} ->
			{ok, Record};
		{atomic, []} ->
			{error, not_found}
	end.

read_all_contacts() ->
	F = fun() -> mnesia:select(contact,[{'_',[],['$_']}]) end,
	try mnesia:activity(transaction, F) of
		Contacts -> Contacts
	catch 
		_:_ -> []
	end.

%% if successful, returns {atomic, ok}
write_alqa(Alqa) ->
    Fun = fun() ->
		mnesia:write(Alqa)
	end,
    mnesia:transaction(Fun).

read_alqa(Id) ->
	Fun = fun() ->
		mnesia:read({alqa, Id})
	end,
	case mnesia:transaction(Fun) of
		{atomic,[Record]} ->
			{ok, Record};
		{atomic, []} ->
			{error, not_found}
	end.

read_all_alqas() ->
	F = fun() -> mnesia:select(alqa,[{'_',[],['$_']}]) end,
	try mnesia:activity(transaction, F) of
		Contacts -> Contacts
	catch 
		_:_ -> []
	end.

% -record(self_address, {
% 		%% The address string value	
% 		id 				,%= undefined,
% 		%% own, net, allcall, selective allcall, anycal, selective anycall
% 		type 			,%= undefined,
% 		%% If type is net, respond with net_member as self address; if left none, while type=net, receive only 
% 		net_member		,%= none, 
% 		%% If type is net, for anycall use random for others must set. If this is "other station net" address, this is a list of slots.
% 		net_slot		,%= [random], 
% 		%% List of allowed channels, or all
% 		channels		,%= [all],
% 		%% This specifies expected reply time 
% 		wait_for_reply_time %= default
% 	}).

%% if successful, returns {atomic, ok}
write_self_address(Id, Type, NetMember, NetSlot, Channels, WaitForReplyTime) ->
	Sa = 	#self_address{	id = Id,
							type = Type,
							net_member = NetMember,
							net_slot = NetSlot,
							channels = Channels,
							wait_for_reply_time = WaitForReplyTime
				},
    Fun = fun() ->
		mnesia:write(Sa)
	end,
    mnesia:transaction(Fun).

read_self_address(Id) ->
	Fun = fun() ->
		mnesia:read({self_address, Id})
	end,
	case mnesia:transaction(Fun) of
		{atomic,[Record]} ->
			{ok, Record};
		{atomic, []} ->
			{error, not_found}
	end.

%% if successful, returns {atomic, ok}
write_other_address(Id, Type, NetMember, NetSlot, Channels, WaitForReplyTime) ->
	Sa = 	#other_address{	id = Id,
							type = Type,
							net_member = NetMember,
							net_slot = NetSlot,
							channels = Channels,
							wait_for_reply_time = WaitForReplyTime
				},
    Fun = fun() ->
		mnesia:write(Sa)
	end,
    mnesia:transaction(Fun).

read_other_address(Id) ->
	Fun = fun() ->
		mnesia:read({other_address, Id})
	end,
	case mnesia:transaction(Fun) of
		{atomic,[Record]} ->
			{ok, Record};
		{atomic, []} ->
			{error, not_found}
	end.	