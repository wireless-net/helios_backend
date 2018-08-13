%% Copyright (c) 2018  Devin Butterfield
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
%% ALQA functionality (refer to MIL-STD-187-721D for details)
%%
-module(alqa).

-export([
        gen_hist/0
    ,   gen_hist_list/1 
    ,   init_alqa_stats/6
    ,   shift_epoch_hist/1
    ,   integrate_epoch_hist/2
    ,   vecadd/3
    ,   normalize_hist/1
    ,   normalize_hist/3
    ,   average_epoch_hist/1
    ,   average_epoch_hist/3
    ,   histogram_pber/1
        ]).

-export([start_link/0]).
-export([init/0]).

-include("alqa.hrl").

start_link() ->
    Pid = spawn_link(?MODULE, init, []),
    {ok, Pid}.

init() ->
    lager:info("ALQA server starting..."),
    register(alqa_server_proc, self()),
    process_flag(trap_exit, true),
    loop().

%% Do vector addition of two lists containing integers
vecadd([], [], Result) ->
    lists:reverse(Result);
vecadd([A|Avec], [B|Bvec], Result) ->
    Sum = A+B,
    vecadd(Avec, Bvec, [Sum|Result]).

%% generate new histogram list with bins initialized to zero
gen_hist() ->
    [0 || _X <- lists:seq(1,?ALQA_STAT_MEASURES)]. 

%% generate list of histograms with bins initialized to zero
gen_hist_list(Count) ->
    [gen_hist() || _X <- lists:seq(1,Count)].

%% init complete ALQA record
init_alqa_stats(Id, Time, Channel, Frequency, Ber, Sinad) ->
    #alqa{
        id_freq={Id, Frequency}, 
        time=Time, 
        channel=Channel,
        ber=Ber,
        sinad=Sinad,
        epoch_1_hist=gen_hist_list(15),  %% 15 minute epoch, 1 min integration
        epoch_1_hist_avg=gen_hist(),  %% 15 minute epoch avg
        epoch_2_hist=gen_hist_list(12),  %% 60 minute epoch, 5 min integration
        epoch_2_hist_avg=gen_hist(),  %% 60 minute epoch avg
        epoch_3_hist=gen_hist_list(24),  %% 24 hour epoch, 60 min integration
        epoch_3_hist_avg=gen_hist(),  %% 24 hour epoch avg
        epoch_4_hist=gen_hist()}.      %% all time epoch

%% shift the given Epoch list of histograms to the right, pushing new zeroed
%% histogram on the front, and dropping the oldest
shift_epoch_hist(EpochList) ->
    lists:droplast([gen_hist()|EpochList]).

%% Integrate new histogram values with the current given histogram 
integrate_epoch_hist([Head|EpochList], NewHistVals) ->
    NewHead = vecadd(Head, NewHistVals,[]),
    [NewHead|EpochList].

normalize_hist([], _Bin1, Norm) ->
    lists:reverse(Norm);
normalize_hist(Hist, 0, _Norm) ->
    Hist;
normalize_hist([Bin|Rest], Bin1, Norm) ->
    normalize_hist(Rest, Bin1, [(float(Bin)/float(Bin1))|Norm]).

%% normalize the given histogram using Bin1
normalize_hist([Bin1|Hist]) ->
    normalize_hist([Bin1|Hist], Bin1, []).

average_epoch_hist([], Acc, Count) ->
    [X / Count || X <- Acc];
average_epoch_hist([Head|EpochList], Acc, Count) ->
    Norm = normalize_hist(Head),
    average_epoch_hist(EpochList, vecadd(Norm, Acc, []), Count + 1).

%% average across all the histograms in an epoch list
average_epoch_hist(EpochList) ->
    average_epoch_hist(EpochList, gen_hist(), 0).

%% generate single sample exceedance histogram ready for integration with
%% current epoch histogram
histogram_pber(Sample) ->
    QuantRef = [-1, 0, 1, 3, 5, 7, 9, 11, 15, 17, 20, 23, 26, 28, 29, 30],
    histogram(Sample, QuantRef, []).

histogram(_Sample, [], Hist) ->
    lists:reverse(Hist);
histogram(Sample, [QuantLevel|QuantRef], Hist) when Sample > QuantLevel ->
    histogram(Sample, QuantRef, [1|Hist]);
histogram(Sample, [_QuantLevel|QuantRef], Hist) ->
    histogram(Sample, QuantRef, [0|Hist]).

loop() ->
    receive
        shutdown ->
            lager:info("got shutdown"),
            exit(normal);
        {'EXIT', _Port, Reason} ->
            lager:info("ALQA server terminated for reason: ~p", [Reason]),
            exit(normal);
        Unhandled ->
            lager:error("ALQA server got unhandled message ~p", [Unhandled]),
            loop()
    end.
