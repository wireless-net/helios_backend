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
#include <stdio.h>
#include "radioif.h"
#include "kx3_control.h"

int main()
{
	radioif_t rif;
	int freq;
	int band;
	int ptt;

	printf("testing kx3 control\n");
	if (kx3_control_init(&rif)) {
		printf("failed to initialize KX3 control\n");
		return -1;
	}

	// test get freq
	if (radioif_get_freq(&rif, &freq)) {
		printf("failed to get freq\n");
		return -1;
	}

	// test get band
	if (radioif_get_band(&rif, &band)) {
		printf("failed to get band\n");
		return -1;
	}

	// test get ptt
	if (radioif_get_ptt(&rif, &ptt)) {
		printf("failed to get ptt\n");
		return -1;
	}

	if (radioif_set_band(&rif, (3+1))) {
		printf("failed to set band\n");
		return -1;
	}
	sleep(1);
	
	if (radioif_set_ptt(&rif, 1)) {
		printf("failed to set ptt\n");
		return -1;
	}
	sleep(1);

	if (radioif_set_ptt(&rif, 0)) {
		printf("failed to set ptt\n");
		return -1;
	}
	sleep(1);

	if (radioif_set_band(&rif, (2+1))) {
		printf("failed to set band\n");
		return -1;
	}

	if (radioif_set_freq(&rif, 5372000)) {
		printf("failed to set freq\n");
		return -1;
	}	
	sleep(1);
	if (radioif_set_freq(&rif, 5371500)) {
		printf("failed to set freq\n");
		return -1;
	}	


	return 0;
}