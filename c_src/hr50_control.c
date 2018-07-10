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
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
#include <poll.h>
#include <syslog.h>

#include "hr50_control.h"
#include "radioif.h"

#define HR50_MAX_RESP_TIME 1000 /* ms */

/* some commands like TQ seem to have latency, and retry is required */
#define HR50_MAX_RETRIES 3

/* speed to baud conversion */
unsigned int speed_to_baud(unsigned int speed)
{
	switch(speed) {
	case 0: return  B0 ;
	case 50: return  B50 ;
	case 75: return  B75 ;
	case 110: return  B110 ;
	case 134: return  B134 ;
	case 150: return  B150 ;
	case 200: return  B200 ;
	case 300: return  B300 ;
	case 600: return  B600 ;
	case 1200: return  B1200 ;
	case 1800: return  B1800 ;
	case 2400: return  B2400 ;
	case 4800: return  B4800 ;
	case 9600: return  B9600 ;
#ifdef B19200
	case 19200: return  B19200 ;
#elif defined(EXTA)
	case 19200: return  EXTA ;
#endif
#ifdef B38400
	case 38400: return  B38400 ;
#elif defined(EXTB)
	case 38400: return  EXTB ;
#endif
#ifdef B57600
	case 57600: return  B57600 ;
#endif
#ifdef B76800
	case 76800: return  B76800 ;
#endif
#ifdef B115200
	case 115200: return  B115200 ;
#endif
#ifdef B153600
	case 153600: return  B153600 ;
#endif
#ifdef B230400
	case 230400: return  B230400 ;
#endif
#ifdef B307200
	case 307200: return  B307200 ;
#endif
#ifdef B460800
	case 460800: return  B460800 ;
#endif
#ifdef B500000
	case 500000: return  B500000 ;
#endif
#ifdef B576000
	case 576000: return  B576000 ;
#endif
#ifdef B921600
	case 921600: return  B921600 ;
#endif
#ifdef B1000000
	case 1000000: return  B1000000 ;
#endif
#ifdef B1152000
	case 1152000: return  B1152000 ;
#endif
#ifdef B1500000
	case 1500000: return  B1500000 ;
#endif
#ifdef B2000000
	case 2000000: return  B2000000 ;
#endif
#ifdef B2500000
	case 2500000: return  B2500000 ;
#endif
#ifdef B3000000
	case 3000000: return  B3000000 ;
#endif
#ifdef B3500000
	case 3500000: return  B3500000 ;
#endif
#ifdef B4000000
	case 4000000: return  B4000000 ;
#endif
	default: return speed;
	}
	return -1;
}

int
open_port(char *port, int speed)
{
	int fd; /* File descriptor for the port */
	struct termios options;

	fd = open(port, O_RDWR | O_NOCTTY/* | O_NDELAY*/);
	if (fd == -1) {
		/*
		* Could not open the port.
		*/
		syslog(LOG_INFO, "open_port: Unable to open %s: %s", port, strerror(errno));
		return fd;
	}

	/*
	 * Get the current options for the port...
	 */

	tcgetattr(fd, &options);

	/*
	 * Set the baud rates
	 */

	cfsetispeed(&options, speed_to_baud(speed));
	cfsetospeed(&options, speed_to_baud(speed));

	/* N81 */
	options.c_cflag &= ~PARENB;
	options.c_cflag &= ~CSTOPB;
	options.c_cflag &= ~CSIZE;
	options.c_cflag |= CS8;

	/*
	 * Enable the receiver and set local mode...
	 */

	options.c_cflag |= (CLOCAL | CREAD);

	options.c_lflag &= ~(ICANON | ECHO | ECHOE | ISIG);

	options.c_iflag &= ~(IXON | IXOFF | IXANY);
	options.c_oflag &= ~OPOST;

	options.c_cc[VMIN]  = 0;
	options.c_cc[VTIME] = 0; // relay on NDELAY
	/*
	 * Set the new options for the port...
	 */

	tcsetattr(fd, TCSANOW, &options);


	return (fd);
}

int hr50_poll_wait(radioif_t *rif)
{
	struct pollfd fdset;
	int timeout = HR50_MAX_RESP_TIME;
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
		syslog(LOG_INFO, "timeout on hr50 serial wait\n");
		return -1;
	}

	if (fdset.revents & POLLIN) {
		return 0;
	} else {
		syslog(LOG_INFO, "unexpected revents=0x%x\n", fdset.revents);
		return -1;
	}
}

int hr50_read_response(radioif_t *rif, char *buf)
{
	int len;
	int ret;

	len = 0;
	while (1) {
		if (hr50_poll_wait(rif)) {
			syslog(LOG_INFO, "error in wait\n");
			return -1;
		}
		ret = read(rif->handle, &buf[len], 80);
		if (ret <= 0) {
			syslog(LOG_INFO, "failure in read %d\n",ret);
			return -1;
		}

		len += ret;
		if (buf[len-1] != ';') {
			continue;
		}
		return 0;		
	}
}

int hr50_set_band(radioif_t *rif, int band)
{
	char buf[80];
	int ret;
	int len;
	int rd_band;

	// simple translation to HR50 band numbers (-1)
	sprintf(buf, "HRBN%02d;", band-1);	
	len = strlen(buf);

	// set the VFO A band		
	ret = write(rif->handle, buf, len);
	if (ret < len) {
		syslog(LOG_INFO, "failure in write\n");
		return -1;
	}

	if (hr50_get_band(rif, &rd_band)) {
		syslog(LOG_INFO, "failed to validate band\n");
		return -1;
	}
	if (rd_band == (band-1)) {
		return 0;
	}

	return -1;
}

int hr50_get_band(radioif_t *rif, int *band)
{
	char buf[80];
	int ret;
	int len;

	sprintf(buf, "HRBN;");
	len = strlen(buf);
	ret = write(rif->handle, buf, len);
	if (ret < len) {
		syslog(LOG_INFO, "failure in write\n");
		return -1;
	}

	hr50_read_response(rif, buf);
	
	sscanf(buf, "BN%2d;", band);
	// syslog(LOG_INFO,"hr50_control: %s called (%d)\n", __PRETTY_FUNCTION__, *band);

	return 0;
}

int hr50_set_freq(radioif_t *rif, int freq)
{
	char buf[80];
	int ret;
	int len;

	// syslog(LOG_INFO,"hr50_control: %s called (%d)\n", __PRETTY_FUNCTION__, freq);
	sprintf(buf, "FA%011d;", freq);	
	len = strlen(buf);

	ret = write(rif->handle, buf, len);
	if (ret < len) {
		syslog(LOG_INFO, "failure in write\n");
		return -1;
	}

	// due to a bug in the HARDROCK-50, following a PTT, the first command doesn't take, and we have to send it again.
	usleep(100000);

	ret = write(rif->handle, buf, len);
	if (ret < len) {
		syslog(LOG_INFO, "failure in write\n");
		return -1;
	}

	return -1;
}

int hr50_get_freq(radioif_t *rif, int *freq)
{
	syslog(LOG_INFO,"hr50_control: %s called (%d)\n", __PRETTY_FUNCTION__, *freq);

	return 0;
}

int hr50_set_ptt(radioif_t *rif, int state)
{
	syslog(LOG_INFO, "HR50 serial SET PTT control not supported\n");
	return -1;	
}

int hr50_get_ptt(radioif_t *rif, int *state)
{
	syslog(LOG_INFO, "HR50 serial GET PTT control not supported\n");
	return -1;	
}

int hr50_set_mode(radioif_t *rif, int state)
{
	syslog(LOG_INFO, "HR50 serial SET MODE control not supported\n");
	return -1;		
}

int hr50_get_mode(radioif_t *rif, int *state)
{
	syslog(LOG_INFO, "HR50 serial GET MODE control not supported\n");
	return -1;
}

int hr50_control_init(radioif_t *rif)
{
	char *device = "/dev/ttyUSB1";

	if ((rif->handle = open_port(device,19200)) < 0) {
		syslog(LOG_INFO,"hr50_control: failed to open serial port\n");
		return -1;
	}
	// radioif_set_band = hr50_set_band;
	// radioif_get_band = hr50_get_band;
	// radioif_set_freq = hr50_set_freq;
	// radioif_get_freq = hr50_get_freq;
	// radioif_set_ptt =  hr50_set_ptt;
	// radioif_get_ptt =  hr50_get_ptt;
	// radioif_set_mode =  hr50_set_mode;
	// radioif_get_mode =  hr50_get_mode;
	sleep(1); // give serial port time to fire up (seems to be needed)	
	return 0;
}