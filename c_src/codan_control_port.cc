/*
 * Copyright (c) 2018  Devin Butterfield
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
 * Radio control interface for CODAN NGT series radios (via canbus)
 */

#include <linux/can.h>
#include <linux/can/raw.h>

#include <stdlib.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>

#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <chrono>
#include <iomanip>
#include <iostream>
#include <thread>

#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>

/* for logging */
#include <syslog.h>

#include <errno.h>
#include "codan_control.h"

#define MAX_BUF 1400

// port command and event codes
#define CMD_SET_BAND 			0x0001
#define CMD_GET_BAND			0x0002
#define CMD_SET_FREQ 			0x0003
#define CMD_GET_FREQ 			0x0004
#define CMD_SET_PTT 			0x0005
#define CMD_GET_PTT 			0x0006
#define CMD_SET_MODE 			0x0007
#define CMD_GET_MODE 			0x0008
#define CMD_SET_CHAN 			0x0009
#define CMD_GET_CHAN 			0x000a

// port return codes
#define RET_OK				0x0000 // 0
#define RET_PTT				0x0001
#define RET_ERR				0xffff // 65535

std::sig_atomic_t signalValue;
int ptt_state;
int chan_state;


int read_cmd(unsigned char *buf);
int read_exact(unsigned char *buf, int len);
int write_cmd(unsigned char *buf, int len);
int write_exact(unsigned char *buf, int len);
void print_can_msg(const struct can_frame &frame);
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

void onSignal(int value) {
    signalValue = static_cast<decltype(signalValue)>(value);
}

int main(int argc, char *argv[])
{
	int ret = 0;
	struct pollfd fdset[2];
	int nfds = 2;
	int timeout;
	int len;
	uint8_t cmdbuf_i[MAX_BUF+4];
	uint8_t cmdbuf_o[MAX_BUF+4];// +4 for op+len
	radioif_t rif;
	uint16_t *cmd_words;
	uint16_t op,res;
	uint16_t *cr;
	int res_data_len;
	size_t write_total;
	int band;
	int freq;
	int chan;
	int ptt;
	int mode;
	
	// init to off
	ptt_state = 0;
	chan_state = chan = 1; // start off on chan 1

    using namespace std::chrono_literals;
    const char* interface;
    struct sigaction sa;

	if (argc != 2) {
		fprintf(stderr, "usage: codan_control_port <CAN interface name>\r\n");
		return 0;
	}
	interface = argv[1];

    /* open the log */
	openlog("codan_control_port", 0, LOG_USER);
	syslog(LOG_INFO, "codan_control_port starting...\n");

	if (codan_control_init(&rif, interface)) {
		syslog(LOG_ERR,"failed to initialize codan control\n");
		return -1;
	}

    // Register signal handlers
    sa.sa_handler = onSignal;
    ::sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    ::sigaction(SIGINT, &sa, nullptr);
    ::sigaction(SIGTERM, &sa, nullptr);
    ::sigaction(SIGQUIT, &sa, nullptr);
    ::sigaction(SIGHUP, &sa, nullptr);

    // Initialize the signal value to zero
    signalValue = 0;

    // Log that the service is up and running
    fprintf(stderr, "codan_control_port started.\r\n");

	timeout = -1;

	// tell codan to jump to initial channel
	codan_set_chan(&rif, chan, false);

	while (signalValue == 0) {
		memset((void*)fdset, 0, sizeof(fdset));

		fdset[0].fd = STDIN_FILENO;
		fdset[0].events = POLLIN;
		fdset[1].fd = rif.handle;
		fdset[1].events = POLLIN;
      
		ret = poll(fdset, nfds, timeout);      

		if (ret < 0) {
			syslog(LOG_ERR,"\npoll() failed!\n");
			return -1;
		}

		if (fdset[1].revents & POLLIN) {
			struct can_frame frame;
			// uint8_t ptt_on_ref[] = {0x41, 0x02, 0x20, 0x31, <CMD CNT> 0x05, 0x78 }
			// Read in a CAN frame
			auto numBytes = ::read(rif.handle, &frame, CAN_MTU);
			switch (numBytes) {
			case CAN_MTU:
				switch (frame.can_id) {
				case 0x171:
					// print_can_msg(frame);
					// 171: 8b 81 79 05 52 01 81 7f 
					if ((frame.data[0] == 0x8b) &&
						(frame.data[1] == 0x81) &&
						// (frame.data[2] == 0x8f) &&
						// (frame.data[3] == 0x09) &&
						// (frame.data[4] == 0x7f) &&
						// (frame.data[5] == chan) &&
						(frame.data[6] == 0x81) &&
						(frame.data[7] == 0x7f)) {
						fprintf(stderr, "CODAN Channel Change: %d\r\n", frame.data[5]);
						chan_state = chan = frame.data[5];
					}
					break;
				case 0x14B:
					// print_can_msg(frame);
					break;
				case 0x68B:
					break;
				case 0x031:
					// fprintf(stderr, "PTT control: ";
					// print_can_msg(frame);

					// PTT ON  031: 41 02 20 31 <CMD CNT> 05 78 
					// PTT OFF 031: 41 02 20 31 <CMD CNT> 00 78 
					if ((frame.data[0] == 0x41) &&
						(frame.data[1] == 0x02) &&
						(frame.data[2] == 0x20) &&
						(frame.data[3] == 0x31) &&
						// byte 4 is command counter byte
						(frame.data[5] == 0x05) &&
						(frame.data[6] == 0x68)) { // or 0x78 if roger beep is set
						
						fprintf(stderr, "CODAN PTT ON\r\n");
						ptt = 1;
						ptt_state = 1;
						cr = (uint16_t *)&cmdbuf_o[0];
						res = RET_PTT;
						*cr = res;
						memcpy(&cmdbuf_o[2], &ptt, sizeof(ptt));
						res_data_len = 4;
						write_cmd(cmdbuf_o, 2+res_data_len);								
					} else if ( (frame.data[0] == 0x41) &&
								(frame.data[1] == 0x02) &&
								(frame.data[2] == 0x20) &&
								(frame.data[3] == 0x31) &&
								// byte 4 is command counter byte
								(frame.data[5] == 0x00) &&
								(frame.data[6] == 0x68)) { // or 0x78 if roger beep is set


						fprintf(stderr,"CODAN PTT OFF\r\n");
						ptt = 0;
						ptt_state = 0;
						cr = (uint16_t *)&cmdbuf_o[0];
						res = RET_PTT;
						*cr = res;
						memcpy(&cmdbuf_o[2], &ptt, sizeof(ptt));
						res_data_len = 4;
						write_cmd(cmdbuf_o, 2+res_data_len);								
					} 			
					break;
				case 0x08B:
					// 08b: 41 02 02 cb 00 00 
					// PTT control confirmation: 08b: 41 02 02 31 85 05 
					if ((frame.data[0] == 0x41) &&
						(frame.data[1] == 0x02) &&
						(frame.data[2] == 0x02) &&
						(frame.data[3] == 0x31) &&
						// byte 4 is command counter byte
						(frame.data[5] == 0x05)) {
						if (!ptt_state) {
							fprintf(stderr, "Confirmed CODAN PTT ON\r\n");			
							ptt_state = 1;
							ptt = 1;											
							cr = (uint16_t *)&cmdbuf_o[0];
							res = RET_PTT;
							*cr = res;
							memcpy(&cmdbuf_o[2], &ptt, sizeof(ptt));
							res_data_len = 4;
							write_cmd(cmdbuf_o, 2+res_data_len);							
						}
					} else if ( (frame.data[0] == 0x41) &&
								(frame.data[1] == 0x02) &&
								(frame.data[2] == 0x02) &&
								(frame.data[3] == 0xcb) &&
								// byte 4 is command counter byte
								(frame.data[5] == 0x00)) {
						if (ptt_state) {
							fprintf(stderr, "Confirmed CODAN PTT OFF\r\n");							
							ptt_state = 0;
							ptt = 0;
							cr = (uint16_t *)&cmdbuf_o[0];
							res = RET_PTT;
							*cr = res;
							memcpy(&cmdbuf_o[2], &ptt, sizeof(ptt));
							res_data_len = 4;
							write_cmd(cmdbuf_o, 2+res_data_len);							
						}
					}					
					// print_can_msg(frame);
					break;
				default:
					// Should never get here if the receive filters were set up correctly
					fprintf(stderr, "Unexpected CAN ID: 0%x\r\n", frame.can_id);
					break;
				}
				break;
			// case CANFD_MTU:
				// TODO: Should make an example for CAN FD
				// break;
			case -1:
				// Check the signal value on interrupt
				if (EINTR == errno)
					break;
				// Delay before continuing
				std::perror("read");
				std::this_thread::sleep_for(100ms);
			default:
				break;
			}
		} else if (fdset[0].revents & POLLIN) {
			/* read command and execute */
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
					if (codan_set_band(&rif, band)) {
						res = RET_ERR;
					}
					res = RET_OK;
				} else {
					syslog(LOG_ERR, "invalid write length for set band %d\n", write_total);
					ret = RET_ERR;
				}
				break;
			case CMD_GET_BAND:
				if (codan_get_band(&rif, &band)) {
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
					if (codan_set_freq(&rif, freq)) {
						res = RET_ERR;
					}
					res = RET_OK;
				} else {
					syslog(LOG_ERR, "invalid write length for set freq %d\n", write_total);
					res = RET_ERR;
				}
				break;
			case CMD_GET_FREQ:
				if (codan_get_freq(&rif, &freq)) {
					res = RET_ERR;
				} else {
					// syslog(LOG_INFO, "get freq %d\n", freq);
					memcpy(&cmdbuf_o[2], &freq, sizeof(freq));
					res = RET_OK;
					res_data_len = 4;
				}
				break;
			case CMD_SET_CHAN:
				write_total = cmd_words[0];
				if (write_total <= sizeof(chan)) {
					memcpy(&chan, &cmdbuf_i[4], sizeof(chan));
					if (chan != chan_state) {
						// selecting new channel, go do it
						if (codan_set_chan(&rif, chan, true)) {
							res = RET_ERR;
						} else {
							// success
							res = RET_OK;
							chan_state = chan;
						}
					} else {
						res = RET_OK;
					}
				} else {
					syslog(LOG_ERR, "invalid write length for set chan %d\n", write_total);
					res = RET_ERR;
				}
				break;
			case CMD_GET_CHAN:
				if (codan_get_chan(&rif, &chan)) {
					res = RET_ERR;
				} else {
					memcpy(&cmdbuf_o[2], &chan, sizeof(chan));
					res = RET_OK;
					res_data_len = 4;
				}
				break;					
			case CMD_SET_PTT:
				write_total = cmd_words[0];
				if (write_total <= sizeof(ptt)) {
					memcpy(&ptt, &cmdbuf_i[4], sizeof(ptt));
					if (ptt != ptt_state) {
						// changing state, go do it
						if (codan_set_ptt(&rif, ptt)) {
							res = RET_ERR;
						} else {
							// success
							ptt_state = ptt;
							res = RET_OK;
						}
					} else {
						res = RET_OK;
					}
				} else {
					syslog(LOG_ERR, "invalid write length for set ptt %d\n", write_total);
					ret = RET_ERR;
				}
				break;
			case CMD_GET_PTT:
				if (codan_get_ptt(&rif, &ptt)) {
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
					if (codan_set_mode(&rif, mode)) {
						res = RET_ERR;
					}
					res = RET_OK;
				} else {
					syslog(LOG_ERR, "invalid write length for set mode %d\n", write_total);
					ret = RET_ERR;
				}
				break;
			case CMD_GET_MODE:
				if (codan_get_mode(&rif, &mode)) {
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

    // Cleanup
    if (::close(rif.handle) == -1) {
        std::perror("close");
        return errno;
    }

    fprintf(stderr, "Got HUP, exiting...\r\n");
    return 0;

    // Error handling (reverse order cleanup)
out:
    ::close(rif.handle);
	syslog(LOG_INFO, "codan_control_port exiting...\n");
	return errno;
}
