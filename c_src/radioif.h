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

#ifndef _RADIOIF_H
#define _RADIOIF_H

typedef struct radioif {
	int handle; /* opaque handle (typically file descriptor) */
	/* any other state vars here */
} radioif_t;

// int (*radioif_set_band)(radioif_t *, int);
// int (*radioif_get_band)(radioif_t *, int *);
// int (*radioif_set_freq)(radioif_t *, int);
// int (*radioif_get_freq)(radioif_t *, int *);
// int (*radioif_set_ptt)(radioif_t *, int);
// int (*radioif_get_ptt)(radioif_t *, int *);
// int (*radioif_set_mode)(radioif_t *, int);
// int (*radioif_get_mode)(radioif_t *, int *);

#endif