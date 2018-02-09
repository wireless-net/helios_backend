%% modem records

%% Config table is used to store parameters for this modem:
%% id 			"K6DRS"
%% host_addr	"192.168.1.209"
%% ale_tx_gain 			val
%% default_tx_gain 		val
%% default_tx_gain		val
%% hflink_reports		val
-record(config, {
		name 		:: binary(),
		value		:: binary()
	}).

-record(channel, {
		id 				:: integer(),
		frequency 		:: integer(),
		fband			:: integer(),
		sideband 		:: binary(),
		comm_use 		:: binary(),
		description 	:: binary(),
		net_name 		:: binary(),
		sounding_status :: binary()
	}).

-record(contact, {	
		id 			:: binary(),
		time		:: integer(),
		channel		:: integer(),		
		frequency 	:: integer(),
		ber 		:: integer(),
		sinad 		:: integer(),
		name 		:: binary(),
		coordinates :: binary(),
		power 		:: integer(),
		radio 		:: binary(),
		controller 	:: binary(),
		antenna 	:: binary()
	}).

% -record(fnctrl, {
% 		action			:: binary(),
% 		txspec			:: integer(),
% 		txmode			:: integer(),
% 		tx				:: integer(),
% 		rxspec			:: integer(),
% 		rxmode			:: integer(),
% 		rx				:: integer()
% 	}).

% -record(radioctrl, {
% 		fband 			:: integer(), %% must use "fband" due to clash with "band" which is an erlang operator
% 		freq 			:: integer(),
% 		mode 			:: integer(),
% 		ptt 			:: integer()
% 	}).