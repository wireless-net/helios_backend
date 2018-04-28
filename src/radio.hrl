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
		%% TODO
		% transmit power level
		% traffic or channel use (voice, data, etc.) 58
		% sounding data
		% modulation type (associated with frequency)
		% transmit/receive modes
		% filter width (DO)
		% automatic gain control (AGC) setting (DO)
		% input/output antenna port selection (DO)
		% input/output information port selection (DO)
		% noise blanker setting (DO)
		% security (DO)
		% sounding self address(es) SA....n(DO)
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

-record(self_address, {
		%% The address string value	
		id 				,%= undefined,
		%% own, net, allcall, selective allcall, anycal, selective anycall
		type 			,%= undefined,
		%% If type is net, respond with net_member as self address; if left none, while type=net, receive only 
		net_member		,%= none, 
		%% If type is net, for anycall use random for others must set. If this is "other station net" address, this is a list of slots.
		net_slot		,%= [random], 
		%% List of allowed channels, or all
		channels		,%= [all],
		%% This specifies expected reply time 
		wait_for_reply_time %= default
	}).

-record(other_address, {
		%% The address string value	
		id 				,%= undefined,
		%% own, net, allcall, selective allcall, anycall, selective anycall
		type 			,%= undefined,
		%% If type is net, use net_member as self address
		net_member		,%= none, 
		%% If type is net, this is a list of associated slots, or random
		net_slot		,%= [random], 
		%% List of allowed channels, or all
		channels		,%= [all],
		%% This specifies expected reply time 
		wait_for_reply_time %= default
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