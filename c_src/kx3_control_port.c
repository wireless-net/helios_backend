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
 * 
 * Modem KX3 control interface
 */

#include <stdint.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <getopt.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>

/* for logging */
#include <syslog.h>
#include <errno.h>
#include "radioif.h"
#include "kx3_control.h"

/**************************** Type Definitions *******************************/


/***************** Macros (Inline Functions) Definitions *********************/
 
#define MAX_BUF 1400

#define C_RADIO_TYPE_NULL	0 /* undefined, use default */
#define C_RADIO_TYPE_KX3	1 /* select KX3 */
#define C_RADIO_TYPE_SR		2 /* select softrock */

// port command and event codes
#define CMD_SET_BAND 			0x0001
#define CMD_GET_BAND			0x0002
#define CMD_SET_FREQ 			0x0003
#define CMD_GET_FREQ 			0x0004
#define CMD_SET_PTT 			0x0005
#define CMD_GET_PTT 			0x0006
#define CMD_SET_MODE 			0x0007
#define CMD_GET_MODE 			0x0008

// port return codes
#define RET_OK				0x0000 // 0
#define RET_ERR				0xffff // 65535

/************************** Function Prototypes ******************************/
int read_cmd(unsigned char *buf);
int read_exact(unsigned char *buf, int len);
int write_cmd(unsigned char *buf, int len);
int write_exact(unsigned char *buf, int len);

/************************** Variable Definitions *****************************/


/************************** Functions ****************************************/

int init_radioif(int type, radioif_t *rif)
{
	switch(type) {
	case C_RADIO_TYPE_SR:
		syslog(LOG_INFO,"softrock radioif setup: not implemented\n");
		break;
	case C_RADIO_TYPE_KX3:
		if (kx3_control_init(rif)) {
			syslog(LOG_ERR,"failed to initialize KX3 control\n");
			return -1;
		}
		return 0;
	}
	return -1;
}

/*
 * The following routines taken from the erlang docs
 */
int read_cmd(unsigned char *buf)
{
	int len;

	if (read_exact(buf, 2) != 2)
		return -1;
	len = (int)((buf[0] << 8) | buf[1]);
	return read_exact(buf, len);
}

int read_exact(unsigned char *buf, int len)
{
	int i, got=0;
  
	do {
		if ((i = read(0, buf+got, len-got)) <= 0) {
			return(i);
		}
		got += i;
	} while (got<len);

	return(len);
}

int write_cmd(unsigned char *buf, int len)
{
	unsigned char b;

	b = (len >> 8) & 0xff;
	write_exact(&b, 1);

	b = len & 0xff;
	write_exact(&b, 1);

	return write_exact(buf, len);
}

int write_exact(unsigned char *buf, int len)
{
	int i, wrote = 0;
	do {
		if ((i = write(1, buf+wrote, len-wrote)) <= 0)
			return (i);
		wrote += i;
	} while (wrote<len);

	fflush(stdout);
	return (len);
}


int main(int argc, char *argv[])
{
	int ret = 0;
	// int fd;
	struct pollfd fdset[1];
	int nfds = 1;
	int timeout;
	int len;
	uint8_t cmdbuf_i[MAX_BUF+4];
	uint8_t cmdbuf_o[MAX_BUF+4];// +4 for op+len
	// int i;
	// int j;
	// uint8_t addr;
	// int16_t val;
	radioif_t rif;
	uint16_t *cmd_words;
	uint16_t op,res;
	uint16_t *cr;
	int res_data_len;
	int write_total;
	int band;
	int freq;
	int ptt;
	int mode;

    /* open the log */
	openlog("kx3_control_port", 0, LOG_USER);
	syslog(LOG_INFO, "Modem kx3_control_port starting...\n");

	if (init_radioif(C_RADIO_TYPE_KX3, &rif)) {
		syslog(LOG_ERR,"error: failed to initialize the radio interface\n");
		return -1;
	}

	// // make sure PTT off
	// if (radioif_set_ptt(&rif, 0)) {
	// 	syslog(LOG_ERR,"failed to set ptt\n");
	// 	return -1;
	// }
	// // set initial BAND
	// if (radioif_set_band(&rif, c_radio_band)) {
	// 	syslog(LOG_ERR,"failed to set band\n");
	// 	return -1;
	// }
	// // set initial FREQ
	// if (radioif_set_freq(&rif, c_radio_frequency[c_radio_band])) {
	// 	syslog(LOG_ERR,"failed to set freq\n");
	// 	return -1;
	// }	

	// TODO: set AGC off
	// TODO: set RF gain (kx3 to about -19)
	// TODO: set USB/LSB mode
	// TODO: Mic gain ()
	// TODO: set volume (kx3 to ~3-4)
	// TODO: enable tune function
	// TODO: load all channel data (names, frequencies)
	// TODO: load all ALE settings

	timeout = -1;
 
 	// p32 = (int32_t *)&write_data[0];
	while (1) {
		memset((void*)fdset, 0, sizeof(fdset));

		fdset[0].fd = STDIN_FILENO;
		fdset[0].events = POLLIN;
      
		ret = poll(fdset, nfds, timeout);      

		if (ret < 0) {
			syslog(LOG_ERR,"\npoll() failed!\n");
			return -1;
		}

		if (fdset[0].revents & POLLIN) {
			/* read command and execute */
			// int do_tx;
			// syslog(LOG_INFO, "got input!\n");

			len = read_cmd(cmdbuf_i);
			if (len <= 0) {
				/* something went wrong, or time to exit */
				goto out;
			}

			/* handle command */
			cr = (uint16_t *)&cmdbuf_i[0];
			cmd_words = (uint16_t *)&cmdbuf_i[2];
			op = *cr;

			// syslog(LOG_INFO, "got command, op=0x%x, len=%d\n", op,len);
			
			res_data_len = 0;
			// handle all write and read commands
			res = RET_ERR;
			switch (op) {
			case CMD_SET_BAND:
				write_total = cmd_words[0];
				if (write_total <= sizeof(band)) { 
					memcpy(&band, &cmdbuf_i[4], sizeof(band));
					syslog(LOG_INFO, "set band %d\n", band);
					if (radioif_set_band(&rif, band)) {
						res = RET_ERR;
					}
					res = RET_OK;
				} else {
					syslog(LOG_ERR, "invalid write length for set band %d\n", write_total);
					ret = RET_ERR;
				}
				break;
			case CMD_GET_BAND:
				if (radioif_get_band(&rif, &band)) {
					res = RET_ERR;
				} else {
					syslog(LOG_INFO, "get band %d\n", band);
					memcpy(&cmdbuf_o[2], &band, sizeof(band));
					res = RET_OK;
					res_data_len = 4;
				}
				break;				
			case CMD_SET_FREQ:
				write_total = cmd_words[0];
				if (write_total <= sizeof(freq)) {
					memcpy(&freq, &cmdbuf_i[4], sizeof(freq));
					// syslog(LOG_INFO, "set freq %d\n", write_total);
					if (radioif_set_freq(&rif, freq)) {
						res = RET_ERR;
					}
					res = RET_OK;
				} else {
					syslog(LOG_ERR, "invalid write length for set freq %d\n", write_total);
					res = RET_ERR;
				}
				break;
			case CMD_GET_FREQ:
				if (radioif_get_freq(&rif, &freq)) {
					res = RET_ERR;
				} else {
					// syslog(LOG_INFO, "get freq %d\n", freq);
					memcpy(&cmdbuf_o[2], &freq, sizeof(freq));
					res = RET_OK;
					res_data_len = 4;
				}
				break;	
			case CMD_SET_PTT:
				write_total = cmd_words[0];
				if (write_total <= sizeof(ptt)) {
					memcpy(&ptt, &cmdbuf_i[4], sizeof(ptt));
					syslog(LOG_INFO, "set ptt %d\n", ptt);
					if (radioif_set_ptt(&rif, ptt)) {
						res = RET_ERR;
					}
					res = RET_OK;
				} else {
					syslog(LOG_ERR, "invalid write length for set ptt %d\n", write_total);
					ret = RET_ERR;
				}
			case CMD_GET_PTT:
				if (radioif_get_ptt(&rif, &ptt)) {
					res = RET_ERR;
				} else {
					syslog(LOG_INFO, "get ptt %d\n", ptt);
					memcpy(&cmdbuf_o[2], &ptt, sizeof(ptt));
					res = RET_OK;
					res_data_len = 4;
				}
				break;
			case CMD_SET_MODE:
				write_total = cmd_words[0];
				if (write_total <= sizeof(mode)) {
					memcpy(&mode, &cmdbuf_i[4], sizeof(mode));
					// syslog(LOG_INFO, "set mode %d\n", mode);
					if (radioif_set_mode(&rif, mode)) {
						res = RET_ERR;
					}
					res = RET_OK;
				} else {
					syslog(LOG_ERR, "invalid write length for set mode %d\n", write_total);
					ret = RET_ERR;
				}
			case CMD_GET_MODE:
				if (radioif_get_mode(&rif, &mode)) {
					res = RET_ERR;
				} else {
					// syslog(LOG_INFO, "get mode %d\n", mode);
					memcpy(&cmdbuf_o[2], &mode, sizeof(mode));
					res = RET_OK;
					res_data_len = 4;
				}
				break;				
			default:
				syslog(LOG_INFO, "error: invalid command %x\n", op);
				res = RET_ERR;
				exit(-1);
			}
			// syslog(LOG_INFO, "sending result, len=%d, res=%x\n", res_data_len, res);
			
			/* handle result */
			cr = (uint16_t *)&cmdbuf_o[0];
			*cr = res;
			write_cmd(cmdbuf_o, 2+res_data_len);
		}
	}

out:
	syslog(LOG_INFO, "kx3_control_port exiting...\n");
	return ret;
}
