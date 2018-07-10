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
 */

#include <linux/can.h>
#include <linux/can/raw.h>

// #include <stdio.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <poll.h>
#include <syslog.h>

#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <iostream>

#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "codan_control.h"

#define CODAN_MAX_RESP_TIME 1000 /* ms */
#define CODAN_MAX_RETRIES 3

void print_can_msg(const struct can_frame &frame) 
{
	fprintf(stderr, "%.3x: ", frame.can_id);
	for (int i = 0; i < frame.can_dlc; i++) {
		fprintf(stderr, "%.2x ", frame.data[i]);
	}
	std::cerr << "\r" << std::endl;
}

int
open_port(const char *interface)
{
    struct sockaddr_can addr;
    struct ifreq ifr;
    int sockfd;
	int rc;

	// Open the CAN network interface
    sockfd = socket(PF_CAN, SOCK_RAW, CAN_RAW);
    if (-1 == sockfd) {
        std::perror("socket");
        return errno;
    }

    // Set a receive filter so we only receive select CAN IDs
	struct can_filter filter[5];
	filter[0].can_id   = 0x171;
	filter[0].can_mask = CAN_SFF_MASK;
	filter[1].can_id   = 0x14B;
	filter[1].can_mask = CAN_SFF_MASK;
	filter[2].can_id   = 0x68B;
	filter[2].can_mask = CAN_SFF_MASK;
	filter[3].can_id   = 0x031;
	filter[3].can_mask = CAN_SFF_MASK;
	filter[4].can_id   = 0x08B;
	filter[4].can_mask = CAN_SFF_MASK;

	rc = setsockopt(sockfd,
					SOL_CAN_RAW,
					CAN_RAW_FILTER,
					&filter,
					sizeof(filter)
					);
	if (-1 == rc) {
		std::perror("setsockopt filter");
		return errno;
	}

    // Enable reception of CAN FD frames
	int enable = 1;

	rc = ::setsockopt(
						sockfd,
						SOL_CAN_RAW,
						CAN_RAW_FD_FRAMES,
						&enable,
						sizeof(enable)
					);
	if (-1 == rc) {
		std::perror("setsockopt CAN FD");
		return errno;
	}

    // Get the index of the network interface
    std::strncpy(ifr.ifr_name, interface, IFNAMSIZ);
    if (ioctl(sockfd, SIOCGIFINDEX, &ifr) == -1) {
        std::perror("ioctl");
		return errno;
    }

    // Bind the socket to the network interface
    addr.can_family = AF_CAN;
    addr.can_ifindex = ifr.ifr_ifindex;
    rc = ::bind(
        sockfd,
        reinterpret_cast<struct sockaddr*>(&addr),
        sizeof(addr)
    );
    if (-1 == rc) {
        std::perror("bind");
        return errno;
    }

	return sockfd;
}

int codan_poll_wait(radioif_t *rif)
{
	struct pollfd fdset;
	int timeout = CODAN_MAX_RESP_TIME;
	int nfds = 1;
	int ret;

	memset((void*)&fdset, 0, sizeof(fdset));
	
	fdset.fd = rif->handle;
	fdset.events = POLLIN;
	
	ret = poll(&fdset, nfds, timeout);
	if (ret < 0) {
		syslog(LOG_INFO, "\npoll() failed!\n");
		return -1;
	}
	if (ret == 0) {
		syslog(LOG_INFO, "timeout on socket wait\n");
		return -1;
	}

	if (fdset.revents & POLLIN) {
		return 0;
	} else {
		syslog(LOG_INFO, "unexpected revents=0x%x\n", fdset.revents);
		return -1;
	}
}

int codan_read_response(radioif_t *rif, struct can_frame *frame, int *expected)
{
	while (1) {
		if (codan_poll_wait(rif)) {
			syslog(LOG_INFO, "error in wait\n");
			return -1;
		}
        // Read in a CAN frame
        int numBytes = read(rif->handle, frame, CAN_MTU);
        switch (numBytes) {
        case CAN_MTU:
			if (frame->can_id == (unsigned int)expected[0]) {
				for (int i = 1; i < 9; i++) {
					if ((expected[i] >= 0) && (expected[i] != frame->data[i-1])) {
						syslog(LOG_INFO, "unexpected CAN message 0x%.3x", frame->can_id);
						continue;
					}
				}
				// got it, we're done				
			}
			// FIXME: should we buffer this and check it upon return???
			return 0;
        case -1:
            // Check the signal value on interrupt
            // if (EINTR == errno)
                // continue;
            std::perror("read");
			return -1;
        default:
            std::cout << "unexpected num bytes read from can interface" << std::endl;
			return -1;
        }
	}
	// shouldn't reach here
	return -1;	
}

int codan_set_band(radioif_t *rif, int band)
{
	syslog(LOG_INFO,"codan_control: %s called (%d): not supported\n", __PRETTY_FUNCTION__, band);
	return -1;
}

int codan_get_band(radioif_t *rif, int *band)
{
	syslog(LOG_INFO,"codan_control: %s called (%d): not supported\n", __PRETTY_FUNCTION__, *band);
	return -1;
}

int codan_set_freq(radioif_t *rif, int freq)
{
	syslog(LOG_INFO,"codan_control: %s called (%d): not supported\n", __PRETTY_FUNCTION__, freq);
	return -1;
}

int codan_get_freq(radioif_t *rif, int *freq)
{
	syslog(LOG_INFO,"codan_control: %s called (%d): not supported\n", __PRETTY_FUNCTION__, *freq);
	return -1;
}

int codan_set_chan(radioif_t *rif, int chan, bool wait_for_resp)
{
	struct can_frame frame;
	int err;

	// prevent invalid channels (must be > 1)
	if (chan < 1) { return -1; }

	for (int retries = 0; retries < CODAN_MAX_RETRIES; retries++) {
		frame.can_id  = 0x171;
		frame.data[0] = 0x8B; 
		frame.data[1] = 0x00; 
		frame.data[2] = 0x06; 
		frame.data[3] = 0xC0; 
		frame.data[4] = 0x80; 
		frame.data[5] = 0x80; 
		frame.data[6] = 0x01; 
		frame.data[7] = 0x0C;
		frame.can_dlc = 8;
		err = ::write(rif->handle, &frame, sizeof(struct can_frame));
		if (err != sizeof(struct can_frame)) {
			std::perror("write");
			syslog(LOG_INFO, "error during socketcan write");
			return -1;
		}	
		frame.can_id  = 0x171;
		frame.data[0] = 0x8B; // cmd byte 1
		frame.data[1] = 0x81; // cmd byte 2
		frame.data[2] = 0x00; // cmd counter byte
		frame.data[3] = 0x05; // chan number byte??
		frame.data[4] = 0x52; // chan number bytes??
		frame.data[5] = chan; // channel number 
		frame.data[6] = 0x81; // ??
		frame.data[7] = 0x7F; // ??
		frame.can_dlc = 8;
		err = ::write(rif->handle, &frame, sizeof(struct can_frame));
		if (err != sizeof(struct can_frame)) {
			std::perror("write");
			syslog(LOG_INFO, "error during socketcan write");
			return -1;			
		}

		// wait for response
		int expected[9] = { 0x171, 0x8b, 0x41, -1, -1, -1, chan, 0x03, 0x0f };
		if (codan_read_response(rif, &frame, expected)) {
			syslog(LOG_INFO, "error waiting for chan command response");
			continue;
		}
		return 0;
			// check if this is message we're expecting
			// 171: 8b 41 <8f> 09 7f 04 03 0f
			// if ((frame.data[0] == 0x8b) &&
			// 	(frame.data[1] == 0x41) &&
			// 	// (frame.data[2] == 0x8f) &&
			// 	// (frame.data[3] == 0x09) &&
			// 	// (frame.data[4] == 0x7f) &&
			// 	(frame.data[5] == chan) &&
			// 	(frame.data[6] == 0x03) &&
			// 	(frame.data[7] == 0x0f)) {
			// 	std::cerr << "Confirmed CODAN channel change\r" << std::endl;
			// 	return 0;
			// } else {
			// 	std::cerr << "no match: " << std::endl;
			// 	print_can_msg(frame);
			// 	continue;
			// }
		//}
		// return 0;
	}
	return -1;
}

int codan_get_chan(radioif_t *rif, int *chan)
{
	// 
	return -1;
}

int codan_set_ptt(radioif_t *rif, int state)
{
	int ret;
	// int len;
	// int rd_state;
	struct can_frame frame;

	// these values determined by sniffing the canbus!!
	frame.can_id = 0x031;
	frame.can_dlc = 7;
	frame.data[0] = 0x41;
	frame.data[1] = 0x02;
	frame.data[2] = 0x20;
	frame.data[3] = 0x31;
	frame.data[4] = 0x83;

	if (state) {
        // the following byte value sets the PTT state to ON
		std::cerr << "codan PTT on\r" << std::endl;
        frame.data[5] = 0x05;
	}
	else {
        // the following byte value sets the PTT state to OFF
		std::cerr << "codan PTT off\r" << std::endl;
        frame.data[5] = 0x00;
	}
	frame.data[6] = 0x68; // 0x78 will cause PTT roger beep		
	
	for (int retries = 0; retries < CODAN_MAX_RETRIES; retries++) {
		// set the PTT state		
		std::cerr << "doing write\r" << std::endl;
		ret = ::write(rif->handle, &frame, sizeof(struct can_frame));
		if (ret != sizeof(struct can_frame)) {
			std::perror("write");
			syslog(LOG_INFO, "failure in write");
			return -1;
		} 

		int expected[9] = { 0x08b, 0x41, 0x02, 0x02, -1, -1, 0, -1 -1};
		if (state) {
			// 08b: 41 02 02 cb 00 00 
			// PTT control confirmation: 08b: 41 02 02 31 85 05 
			// if ((frame.data[0] == 0x41) &&
			// 	(frame.data[1] == 0x02) &&
			// 	(frame.data[2] == 0x02) &&
			// 	(frame.data[3] == 0x31) &&
			// 	// byte 4 is command counter byte
			// 	(frame.data[5] == 0x05)) {
			// 	std::cerr << "Confirmed CODAN PTT ON\r" << std::endl;
			// 	return 0;
			// } else {
			// 	syslog(LOG_INFO, "error PTT command response incorrect, retry...");
			// 	continue;
			// }
			expected[6] = 0x05;
		} else {
			// if ((frame.data[0] == 0x41) &&
			// 	(frame.data[1] == 0x02) &&
			// 	(frame.data[2] == 0x02) &&
			// 	(frame.data[3] == 0xcb) &&
			// 	// byte 4 is command counter byte
			// 	(frame.data[5] == 0x00)) {
			// 	std::cerr << "Confirmed CODAN PTT OFF\r" << std::endl;
			// 	return 0;
			// } else {
			// 	syslog(LOG_INFO, "error PTT command response incorrect, retry...");
			// 	continue;
			// }
			expected[6] = 0x00;
		}

		// wait for response indicating PTT is set accordingly
		//  slcan0  08B   [6]  41 02 02 31 8C 05 (Example)
		std::cerr << "going to wait\r" << std::endl;
		if (codan_read_response(rif, &frame, expected)) {
			syslog(LOG_INFO, "error waiting for PTT command response");
			return -1;
		}
		return 0;
	}
	return -1;	
}

int codan_get_ptt(radioif_t *rif, int *state)
{
	syslog(LOG_INFO,"codan_control: %s called (%d): not supported\n", __PRETTY_FUNCTION__, *state);
	return -1;
}

int codan_set_mode(radioif_t *rif, int state)
{
	syslog(LOG_INFO,"codan_control: %s called (%d): not supported\n", __PRETTY_FUNCTION__, state);
	return -1;	
}

int codan_get_mode(radioif_t *rif, int *state)
{
	syslog(LOG_INFO,"codan_control: %s called (%d): not supported\n", __PRETTY_FUNCTION__, *state);
	return -1;
}

int codan_control_init(radioif_t *rif, const char *interface)
{
	if ((rif->handle = open_port(interface)) < 0) {
		syslog(LOG_INFO,"codan_control: failed to open can interface\n");
		return -1;
	}
	// radioif_set_band = codan_set_band;
	// radioif_get_band = codan_get_band;
	// radioif_set_freq = codan_set_freq;
	// radioif_get_freq = codan_get_freq;
	// radioif_set_ptt =  codan_set_ptt;
	// radioif_get_ptt =  codan_get_ptt;
	// radioif_set_mode =  codan_set_mode;
	// radioif_get_mode =  codan_get_mode;
	return 0;
}