/*
 * Copyright (c) 2017  Devin Butterfield
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */
#ifndef _KX3_CONTROL_H
#define _KX3_CONTROL_H

#include "radioif.h"

unsigned int speed_to_baud(unsigned int speed);
int open_port(char *port, int speed);
int kx3_poll_wait(radioif_t *rif);
int kx3_read_response(radioif_t *rif, char *buf);
int kx3_set_band(radioif_t *rif, int band);
int kx3_get_band(radioif_t *rif, int *band);
int kx3_set_freq(radioif_t *rif, int freq);
int kx3_get_freq(radioif_t *rif, int *freq);
int kx3_set_ptt(radioif_t *rif, int state);
int kx3_get_ptt(radioif_t *rif, int *state);
int kx3_set_mode(radioif_t *rif, int state);
int kx3_get_mode(radioif_t *rif, int *state);
int kx3_control_init(radioif_t *rif);


#endif