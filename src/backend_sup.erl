-module(backend_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    % Child1 = ?CHILD(message_server, worker),
    % Child2 = ?CHILD(radio_control_port, worker),
    % Child3 = ?CHILD(pa_control_port, worker),
    Child4 = ?CHILD(ale, worker),
    {ok, { {one_for_one, 5, 10}, [Child4]} }.

