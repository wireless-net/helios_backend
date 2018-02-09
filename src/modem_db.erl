-module(modem_db).

-export([	init_db/1 
			,write_config/2
			,read_config/1
			,write_channel/8
			,read_channel/1
			,write_hflink_channels/0
			,write_contact/1
			,read_contact/1
			,channel_count/0
			,read_all_contacts/0
			,find_channel/1
			,find_auto_channels/0
		]).


-include("modem.hrl").

% must first do this:
% erl -sname backend -mnesia dir "'$PWD/db'"
% mnesia:create_schema([node()]).
% q().
% run_backend, then:
% modem_db:init_db([node()]).
% modem_db:write_config(id, "K6DRS").
% modem_db:write_hflink_channels().

init_db(Nodes) ->
    mnesia:create_table(config, [{disc_copies, Nodes},{attributes, record_info(fields, config)}]),
    mnesia:create_table(channel, [{disc_copies, Nodes},{attributes, record_info(fields, channel)}]),
    mnesia:create_table(contact, [{disc_copies, Nodes},{attributes, record_info(fields, contact)}]).

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
         fun(Chan, Acc) when Chan#channel.sounding_status == <<"Auto Sounding">> ->
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
	write_channel(3, 	1822000, 	0, <<"USB">>, 	<<"DATA/VOICE">>,	<<"Aux/Regional">>, 		<<"01CHFL">>, 	<<"Attended">>),
	write_channel(4, 	1909000, 	0, <<"USB">>, 	<<"DATA/VOICE">>, 	<<"Aux/Regional">>, 		<<"01DHFL">>, 	<<"Attended">>),

	write_channel(5,	3596000,	1, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"03AHFN">>,	<<"Auto">>),
	write_channel(6,	3791000,	1, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"03BHFL">>, 	<<"Attended">>),
	write_channel(7,	3996000,	1, <<"USB">>,	<<"VOICE">>, 		<<"Regional">>, 				<<"03CHFL">>, 	<<"Attended">>),
	write_channel(8, 	3522000,	1, <<"USB">>,	<<"DATA">>,			<<"Aux/Regional">>,		<<"03DHFL">>, 	<<"Attended">>),
	write_channel(9, 	3617000,	1, <<"USB">>,	<<"DATA">>, 		<<"Aux/Regional">>, 		<<"03EHFN">>, 	<<"Auto">>),

	write_channel(10,	5357000,	2, <<"USB">>,	<<"DATA/VOICE">>, 	<<"Primary Intl.">>, 			<<"05AHFL">>, 	<<"Attended">>),
	write_channel(11,	5360000,	2, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"05BHFL">>, 	<<"Attended">>),
	write_channel(12,	5371500,	2, <<"USB">>,	<<"VOICE">>, 		<<"Regional">>, 				<<"05CHFL">>, 	<<"Attended">>),
	
	write_channel(13,	7102000,	3, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"07AHFN">>,	<<"Auto">>),
	write_channel(14,	7185500,	3, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"07BHFL">>, 	<<"Attended">>),
	write_channel(15,	7296000,	3, <<"USB">>,	<<"VOICE">>,		<<"Regional">>, 				<<"07CHFL">>, 	<<"Attended">>),
	write_channel(16, 	7049500,	3, <<"USB">>,	<<"DATA">>, 		<<"Aux/Regional">>, 		<<"07DHFN">>,	<<"Auto">>),

	write_channel(17,	10145500,	4, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"10AHFN">>,	<<"Auto">>),
	write_channel(18, 	10136500,	4, <<"USB">>,	<<"DATA/VOICE">>, 	<<"Aux/Regional">>, 		<<"10BHFL">>,	<<"Attended">>),

	write_channel(19,	14109000,	5, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"14AHFN">>,	<<"Auto">>),
	write_channel(20,	14346000,	5, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"14BHFL">>, 	<<"Attended">>),
	write_channel(21, 	14100500,	5, <<"USB">>,	<<"DATA">>,			<<"Aux/Testing">>,		<<"14CHFN">>,	<<"Auto">>), 

	write_channel(22,	18106000,	6, <<"USB">>,	<<"DATA">>,			<<"Primary Intl.">>, 			<<"18AHFN">>,	<<"Auto">>),
	write_channel(23,	18117500,	6, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"18BHFL">>, 	<<"Attended">>),
	write_channel(24,	21096000,	7, <<"USB">>,	<<"DATA">>, 		<<"Primary Intl.">>, 			<<"21AHFN">>,	<<"Auto">>),
	write_channel(25,	21432500,	7, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 			<<"21BHFL">>, 	<<"Attended">>).


	% write_channel(25, 	24926000,	<<"USB	DATA Auxiliary 24AHFN	Auto Attended
	% write_channel(26, 	24932000,	<<"USB	VOICE Auxiliary 24BHFL Attended
	% write_channel(27,	28146000,	9, <<"USB">>,	<<"DATA PRIMARY">>, <<"International">>, 	<<"HFN">>,		<<"Auto">>),
	% write_channel(28,	28312500,	9, <<"USB">>,	<<"VOICE">>, 		<<"International">>, 	<<"HFL">>, 		<<"Attended">>).	


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
	mnesia:activity(transaction, F).