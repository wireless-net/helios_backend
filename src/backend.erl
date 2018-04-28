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
