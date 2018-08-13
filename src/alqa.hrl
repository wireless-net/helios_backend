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
-record(alqa, {
		id_freq 			= {<<>>, 0},
		time		        = 0,
        channel             = 0,
		ber 		        = 0,
		sinad 		        = 0,
        epoch_1_hist        = [[]], %% list of 1 minute intervals up to 15 minutes, 0...14        
        epoch_1_hist_avg    = [], %% list of 1 minute intervals up to 15 minutes, 0...14        
        epoch_2_hist        = [[]], %% list of 5 minute intervals up to 1 hour, 0...11
        epoch_2_hist_avg    = [], %% list of 5 minute intervals up to 1 hour, 0...11
        epoch_3_hist        = [[]], %% list of 60 minute intervals up to 24 hours, 0...23
        epoch_3_hist_avg    = [], %% list of 60 minute intervals up to 24 hours, 0...23
        epoch_4_hist        = []  %% integrates for all time
        }).

-record(alqa_report_stat, {
        channel             :: integer(),
        frequency           :: integer(),
        epoch_1_hist_avg    :: [integer()], %% average of 1 minute intervals over 15 minutes
        epoch_2_hist_avg    :: [integer()], %% average of 5 minute intervals over 1 hour
        epoch_3_hist_avg    :: [integer()], %% average of 60 minute intervals over 24 hours
        epoch_4_hist        :: [integer()]  %% integration for all time for this ID/Frequency
        }).

-record(alqa_report, {
        id                  :: binary(),
        time                :: integer(),
        ber                 :: integer(),
        stats               :: [#alqa_report_stat{}]
        }).

-define(ALQA_STAT_MEASURES, 16). %% number of measures to be histogrammed