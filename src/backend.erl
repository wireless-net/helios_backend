%%%-------------------------------------------------------------------
%%% @copyright (C) 2016, Devin Butterfield
%%%-------------------------------------------------------------------

%%
%% Backend application entry point
%%

-module(backend).

%%% API
-export([
         start/0,
         stop/0
        ]).

%%%===================================================================
%%% API
%%%===================================================================

start() ->
    lager:start(),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel(lager_file_backend, "log/console.log", info),
    mnesia:start(),
    application:start(ranch),
    application:start(crypto),
    application:start(cowlib),
    application:start(cowboy),
    application:start(backend),
    application:start(inets).

stop() ->
    application:stop(inets),
    application:stop(backend),
    application:stop(cowboy),
    application:stop(cowlib),
    application:stop(crypto),
    application:stop(ranch),
    mnesia:stop(),
    lager:stop().
