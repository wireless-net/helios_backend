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
 * Modem Backend to Frontend interface
 */

#include <stdint.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <getopt.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>

#include <netdb.h>
#include <sys/types.h> 
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* for logging */
#include <syslog.h>
#include <errno.h>

/**************************** Type Definitions *******************************/

/***************** Macros (Inline Functions) Definitions *********************/
 
#define POLL_TIMEOUT        (-1) //(3 * 1000) /* 3 seconds */
#define NET_BUF_SIZE		1500
#define NET_FRAME_SIZE		1400
#define TX_FIFO_SIZE        800
#define RX_FIFO_SIZE        (4 * NET_BUF_SIZE)

#define PORT_RXCHAIN		12348// was normally 12346, but change for testing
#define PORT_TXCHAIN		12347

#define TXRX_BUF_SIZE 		200
#define ALE_TXRX_BUF_SIZE 	4

#define RX_CHAIN_DRDY_EVT 	0x01
#define TX_CHAIN_EMPT_EVT 	0x02
#define TX_CHAIN_FULL_EVT 	0x04
#define TX_CHAIN_DONE_EVT 	0x08
#define ALE_RX_DRDY_EVT		0x10
#define ALE_TX_EMPT_EVT 	0x20
#define	ALE_TX_FULL_EVT 	0x40
#define ALE_TX_DONE_EVT 	0x80

// port command and event codes
#define CMD_TXDATA 			0x0001
#define CMD_FNCTRL 			0x0002
#define CMD_NCOINC 			0x0003
#define CMD_CLADDR 			0x0004
#define CMD_TXGAIN 			0x0005
#define CMD_RXGAIN 			0x0006
#define CMD_ALETXGAIN 		0x0007

#define EVT_ALE_RXDATA		0x1001 // 4097
#define EVT_TXEMPT			0x1002 // 4098
#define EVT_ALE_TXDONE		0x1003 // 4099
#define EVT_TXDONE 			0x1004 // 4100
#define EVT_ERROR  			0x1fff

// SPI REGISTER ADDRESSES
#define FNCTRL_REG 				0
#define LO_REG 					1
#define NCO_REG 				2
#define TX_CHAIN_REG 			3
#define RX_CHAIN_REG 			4
#define RES0_REG 				5
#define EVT_REG 				6
#define RESET_REG 				7
#define TXGAIN_REG 				8
#define RXGAIN_REG 				9
#define ALE_TX_CHAIN_REG 		10
#define ALE_RX_CHAIN_REG 		11
// #define ALE_TXGAIN_REG 			12
// #define ALE_RXGAIN_REG 			13

// port return codes
#define RET_OK				0x0000 // 0
#define RET_ERR				0xffff // 65535

/************************** Function Prototypes ******************************/
int read_cmd(unsigned char *buf);
int read_exact(unsigned char *buf, int len);
int write_cmd(unsigned char *buf, int len);
int write_exact(unsigned char *buf, int len);

/************************** Variable Definitions *****************************/

/*
 * network variables
 */
int sockfd_txchain;
struct sockaddr_in clientaddr;  /* clients's addr                   */
size_t clientlen;
struct sockaddr_in hostaddr;  	/* host addr                      	*/

static const char *spi_device = "/dev/spidev0.0";
static uint8_t mode;
static uint8_t bits = 8;
static uint32_t speed = 20000000;//500000;
static uint16_t delay = 1000; // time for device to get ready for next transaction (this sucks!!!)

/****************************************************************
 * gpio_export
 ****************************************************************/
int gpio_export(unsigned int gpio)
{
    int fd, len;
    char buf[MAX_BUF];
    
    fd = open(SYSFS_GPIO_DIR "/export", O_WRONLY);
    if (fd < 0) {
        syslog(LOG_INFO, "%s: gpio/export\n", strerror(errno));
        return fd;
    }
    
    len = snprintf(buf, sizeof(buf), "%d", gpio);
    write(fd, buf, len);
    close(fd);
    
    return 0;
}

/****************************************************************
 * gpio_unexport
 ****************************************************************/
int gpio_unexport(unsigned int gpio)
{
    int fd, len;
    char buf[MAX_BUF];
 
    fd = open(SYSFS_GPIO_DIR "/unexport", O_WRONLY);
    if (fd < 0) {
        syslog(LOG_INFO, "%s: gpio/export\n", strerror(errno));
        return fd;
    }
 
    len = snprintf(buf, sizeof(buf), "%d", gpio);
    write(fd, buf, len);
    close(fd);
    return 0;
}

/****************************************************************
 * gpio_set_dir
 ****************************************************************/
int gpio_set_dir(unsigned int gpio, unsigned int out_flag)
{
    int fd;//, len;
    char buf[MAX_BUF];
 
    snprintf(buf, sizeof(buf), SYSFS_GPIO_DIR  "/gpio%d/direction", gpio);
 
    fd = open(buf, O_WRONLY);
    if (fd < 0) {
        syslog(LOG_INFO, "%s: gpio/direction\n", strerror(errno));
        return fd;
    }
 
    if (out_flag)
        write(fd, "out", 4);
    else
        write(fd, "in", 3);
 
    close(fd);
    return 0;
}

/****************************************************************
 * gpio_set_value
 ****************************************************************/
int gpio_set_value(unsigned int gpio, unsigned int value)
{
    int fd;//, len;
    char buf[MAX_BUF];
 
    snprintf(buf, sizeof(buf), SYSFS_GPIO_DIR "/gpio%d/value", gpio);
 
    fd = open(buf, O_WRONLY);
    if (fd < 0) {
        syslog(LOG_INFO, "%s: gpio/set-value\n", strerror(errno));
        return fd;
    }
 
    if (value)
        write(fd, "1", 2);
    else
        write(fd, "0", 2);
 
    close(fd);
    return 0;
}

/****************************************************************
 * gpio_get_value
 ****************************************************************/
int gpio_get_value(unsigned int gpio, unsigned int *value)
{
    int fd;//, len;
    char buf[MAX_BUF];
    char ch;

    snprintf(buf, sizeof(buf), SYSFS_GPIO_DIR "/gpio%d/value", gpio);
 
    fd = open(buf, O_RDONLY);
    if (fd < 0) {
        syslog(LOG_INFO, "%s: gpio/get-value\n", strerror(errno));
        return fd;
    }
 
    read(fd, &ch, 1);

    if (ch != '0') {
        *value = 1;
    } else {
        *value = 0;
    }
 
    close(fd);
    return 0;
}


/****************************************************************
 * gpio_set_edge
 ****************************************************************/

int gpio_set_edge(unsigned int gpio, char *edge)
{
    int fd;//, len;
    char buf[MAX_BUF];

    snprintf(buf, sizeof(buf), SYSFS_GPIO_DIR "/gpio%d/edge", gpio);
 
    fd = open(buf, O_WRONLY);
    if (fd < 0) {
        syslog(LOG_INFO, "%s: gpio/set-edge\n", strerror(errno));
        return fd;
    }
 
    write(fd, edge, strlen(edge) + 1); 
    close(fd);
    return 0;
}

/****************************************************************
 * gpio_fd_open
 ****************************************************************/

int gpio_fd_open(unsigned int gpio)
{
    int fd;//, len;
    char buf[MAX_BUF];

    snprintf(buf, sizeof(buf), SYSFS_GPIO_DIR "/gpio%d/value", gpio);
 
    fd = open(buf, O_RDONLY | O_NONBLOCK );
    if (fd < 0) {
        syslog(LOG_INFO, "%s: gpio/fd_open\n", strerror(errno));
    }
    return fd;
}

/****************************************************************
 * gpio_fd_close
 ****************************************************************/

int gpio_fd_close(int fd)
{
    return close(fd);
}

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

static void pabort(const char *s)
{
    syslog(LOG_INFO,s);
    abort();
}

static void write_spi(int fd, uint8_t *buf, int len)
{
    int ret;

    struct spi_ioc_transfer tx = {
        .delay_usecs = delay,
        .speed_hz = speed,
        .bits_per_word = bits,
    };
    // send TX data
    tx.tx_buf = (unsigned long)buf;
    tx.len = len * sizeof(uint8_t);
    ret = ioctl(fd, SPI_IOC_MESSAGE(1), &tx);
    if (ret < 1)
        pabort("can't send spi message");
}

static void read_spi(int fd, uint8_t *buf, int len)
{
    int ret;
  
    struct spi_ioc_transfer rx = {
        .delay_usecs = delay,
        .speed_hz = speed,
        .bits_per_word = bits,
    };
    rx.rx_buf = (unsigned long)buf;
    rx.len = len * sizeof(uint8_t);
    ret = ioctl(fd, SPI_IOC_MESSAGE(1), &rx);
    if (ret < 1)
        pabort("can't send spi message");
}

static void write_spi_reg(int fd, uint8_t reg, uint8_t *buf, int len)
{
    reg |= 0x80; // set write bit
    write_spi(fd, &reg, 1);
    write_spi(fd, buf, len);
}

static void read_spi_reg(int fd, uint8_t reg, uint8_t *buf, int len)
{
    write_spi(fd, &reg, 1);
    read_spi(fd, buf, len);
}

void net_init(int portno, int *sockfd)
{
    int optval;                     /* flag value for setsockopt        */

    /* 
     * open the socket
     */
    *sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (*sockfd < 0)  {
        syslog(LOG_INFO, "%s: ERROR: opening socket\n", strerror(errno));
        exit(-1);
    }

    /* 
     * setsockopt: set option that lets us rerun the radio immediately
     * after we kill it; otherwise we have to wait about 20 secs.
     * Eliminates "Address already in use" error.
     */
    optval = 1;
    setsockopt(*sockfd, SOL_SOCKET, SO_REUSEADDR, 
               (const void *)&optval , sizeof(int));

    /*
     * build the host's Internet address
     */
    bzero((char *) &hostaddr, sizeof(hostaddr));
    hostaddr.sin_family = AF_INET;
    hostaddr.sin_addr.s_addr = htonl(INADDR_ANY);
    syslog(LOG_INFO,"binding port %d\n", portno);
    hostaddr.sin_port = htons((unsigned short)portno);

    /*
     * bind: associate the parent socket with a port  
     */ 
    if (bind(*sockfd, (struct sockaddr *) &hostaddr, sizeof(hostaddr)) < 0) {
        syslog(LOG_INFO, "%s: ERROR: on binding\n", strerror(errno));
        exit(-1);
    } 
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
    int fd;
    struct pollfd fdset[3];
    int nfds = 3;
    int gpio_fd, timeout;
    char *buf[MAX_BUF];
    unsigned int gpio;
    int len;
    uint8_t write_data[TXRX_BUF_SIZE];
    uint8_t read_data[TXRX_BUF_SIZE+1];
    uint8_t cmdbuf_i[NET_FRAME_SIZE+4];
    uint8_t cmdbuf_o[NET_FRAME_SIZE+4];// +4 for op+len
    int i;
    // int j;
    // uint8_t addr;
    int32_t *p32;
    int16_t *p16;
    char netbuf[NET_BUF_SIZE];
    uint8_t evt_reg;
    int16_t val;
    // uint32_t uval;
    ringbuf_t tx_fifo;
    ringbuf_t rx_fifo;
    int tx_fifo_buffering = 1;
    // int ptt_mode = 0;
    uint16_t *cmd_words;
    uint16_t op,res;
    uint16_t *cr;
    int res_data_len;
    int write_total;
    // uint32_t tmp_cmd;

    // parse_opts(argc, argv);

    /* open the log */
    openlog("frontend_port", 0, LOG_USER);
    syslog(LOG_INFO, "Modem frontend_port starting...\n");

    // TODO: set AGC off
    // TODO: set RF gain (kx3 to about -19)
    // TODO: set USB/LSB mode
    // TODO: Mic gain ()
    // TODO: set volume (kx3 to ~3-4)
    // TODO: enable tune function
    // TODO: load all channel data (names, frequencies)
    // TODO: load all ALE settings

    // create the TX ring buffer
    if (ringbuf_create(&tx_fifo, TX_FIFO_SIZE)) {
        syslog(LOG_INFO, "%s: failed to initialize the ring buffer\n", strerror(errno));
        return -1;
    }

    // create the RX ring buffer
    if (ringbuf_create(&rx_fifo, RX_FIFO_SIZE)) {
        syslog(LOG_INFO, "%s: failed to initialize the ring buffer\n", strerror(errno));
        return -1;
    }

    /* initialize the network interface */
    net_init(PORT_TXCHAIN, &sockfd_txchain);
    clientlen = sizeof(clientaddr);

    /* setup the GPIO for interrupts */
    gpio = 7; // this also happens to be SPI CE1 on the RPI
    gpio_export(gpio);
    gpio_set_dir(gpio, 0);
    gpio_set_edge(gpio, "rising");
    gpio_fd = gpio_fd_open(gpio);

    /* initialize the SPI device */
    fd = open(spi_device, O_RDWR);
    if (fd < 0)
        pabort("can't open spi_device");

    /*
     * spi mode
     */
    ret = ioctl(fd, SPI_IOC_WR_MODE, &mode);
    if (ret == -1)
        pabort("can't set spi mode");

    ret = ioctl(fd, SPI_IOC_RD_MODE, &mode);
    if (ret == -1)
        pabort("can't get spi mode");

    /*
     * bits per word
     */
    ret = ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits);
    if (ret == -1)
        pabort("can't set bits per word");

    ret = ioctl(fd, SPI_IOC_RD_BITS_PER_WORD, &bits);
    if (ret == -1)
        pabort("can't get bits per word");

    /*
     * max speed hz
     */
    ret = ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed);
    if (ret == -1)
        pabort("can't set max speed hz");

    ret = ioctl(fd, SPI_IOC_RD_MAX_SPEED_HZ, &speed);
    if (ret == -1)
        pabort("can't get max speed hz");

    syslog(LOG_INFO,"spi mode: %d\n", mode);
    syslog(LOG_INFO,"bits per word: %d\n", bits);
    syslog(LOG_INFO,"max speed: %d Hz (%d KHz)\n", speed, speed/1000);

    /*
     * Do initial reset command
     */
    write_data[0] = 0;//7 | 0x80; // reset command / set write bit
    // write_spi(fd, write_data, 1);
    // write_spi(fd, write_data, 1); // dummy data (later this could specify exactly what to reset)
    write_spi_reg(fd, RESET_REG, write_data, 1);
    // and make sure everthing is off

    // write_data[0] = 0 | 0x80; // FN CTRL ADDRESS
    // write_spi(fd, write_data, 1);
    memset(write_data, 0, sizeof(uint32_t));
    write_data[3] = 0xF0; // turn RGB  led OFF / keep codec ON
    write_data[2] = 0x00;
    write_data[1] = 0x00;
    write_data[0] = 0x00;
    // write_spi(fd, write_data, 5); // reg is +1 in size for rx bug workaround
    write_spi_reg(fd, FNCTRL_REG, write_data, 5);

    timeout = POLL_TIMEOUT;
 
    p32 = (int32_t *)&write_data[0];
    while (1) {
        memset((void*)fdset, 0, sizeof(fdset));

        fdset[0].fd = STDIN_FILENO;
        fdset[0].events = POLLIN;
      
        fdset[1].fd = gpio_fd;
        fdset[1].events = POLLPRI;

        fdset[2].fd = sockfd_txchain;
        fdset[2].events = POLLIN;

        ret = poll(fdset, nfds, timeout);      

        if (ret < 0) {
            syslog(LOG_INFO,"\npoll() failed!\n");
            return -1;
        }

        // NOTES:
        // - real time tx/rx audio frames is transmitted/received direct with user app
        // - we receive and handle commands to:
        //   1. send raw TX data frames					CMD_TXDATA
        //   2. send FNCTRL write commands				CMD_FNCTRL
        //   3. send NCO PHASE INC word write commands	CMD_NCOINC
        //   4. ... other modem controls
        // - we send up:
        //   1. modem RX decoded data					EVT_ALE_RXDATA
        //   2. modem error events 						EVT_ERROR

        if (fdset[0].revents & POLLIN) {
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

            res_data_len = 0;
            // handle all write and read commands
            switch (op) {
            case CMD_TXDATA:
                write_total = cmd_words[0];
                // syslog(LOG_INFO, "TX DATA WRITE number to write %d\n", write_total);
                // for (j=0; j < write_total; j++) {
                // syslog(LOG_INFO, "%.2x ", cmdbuf_i[4+j]);
                // }
                memcpy(write_data, &cmdbuf_i[4], write_total);
                write_spi_reg(fd, ALE_TX_CHAIN_REG, write_data, write_total);
                res = RET_OK;
                break;
            case CMD_FNCTRL:
                write_total = cmd_words[0];
                // syslog(LOG_INFO, "FNCTRL bytes to write %d\n", write_total);
                // for (j=0; j < write_total; j++) {
                // syslog(LOG_INFO, "%.2x ", cmdbuf_i[4+j]);
                // }
                // if we are starting the TX chain, set the buffering flag!
                if (cmdbuf_i[4] & 0x8) {
                    tx_fifo_buffering = 1;
                }
                memcpy(write_data, &cmdbuf_i[4], write_total);
                write_spi_reg(fd, FNCTRL_REG, write_data, 5);			
                res = RET_OK;
                break;
            case CMD_NCOINC:
                write_total = cmd_words[0];
                syslog(LOG_INFO, "NCO INC WRITE (implement me!) number to write %d\n", write_total);
                res = RET_OK;
                break;
            case CMD_CLADDR:
                write_total = cmd_words[0];
                // syslog(LOG_INFO, "Client address: bytes to write %d\n", write_total);
                memcpy((char *)&clientaddr.sin_addr.s_addr, (char *)&cmdbuf_i[4], write_total);
                res = RET_OK;
                break;
            case CMD_TXGAIN:
                write_total = cmd_words[0];
                // syslog(LOG_INFO, "TXGAIN: bytes to write %d\n", write_total);
                // for (j=0; j < write_total; j++) {
                // syslog(LOG_INFO, "%.2x ", cmdbuf_i[4+j]);
                // }
                memcpy(write_data, &cmdbuf_i[4], write_total);
                write_spi_reg(fd, TXGAIN_REG, write_data, 5);
                res = RET_OK;
                break;
                // case CMD_ALETXGAIN:
                // 	write_total = cmd_words[0];
                // 	syslog(LOG_INFO, "ALETXGAIN: bytes to write %d\n", write_total);
                //     for (j=0; j < write_total; j++) {
                //     	syslog(LOG_INFO, "%.2x ", cmdbuf_i[4+j]);
                //     }
                // 	memcpy(write_data, &cmdbuf_i[4], write_total);
                // 	// write_spi(fd, write_data, 5); // reg is +1 in size for rx bug workaround
                // 	write_spi_reg(fd, ALE_TXGAIN_REG, write_data, 5);
                // 	res = RET_OK;
                // 	break;				
            case CMD_RXGAIN:
                write_total = cmd_words[0];
                // syslog(LOG_INFO, "RXGAIN: bytes to write %d\n", write_total);
                // for (j=0; j < write_total; j++) {
                // syslog(LOG_INFO, "%.2x ", cmdbuf_i[4+j]);
                // }
                memcpy(write_data, &cmdbuf_i[4], write_total);
                write_spi_reg(fd, RXGAIN_REG, write_data, 5);
                res = RET_OK;
                break;				
            default:
                syslog(LOG_INFO, "error: invalid command %x\n", op);
                res = RET_ERR;
                exit(-1);
            }
			
            /* handle result */
            cr = (uint16_t *)&cmdbuf_o[0];
            *cr = res;
            write_cmd(cmdbuf_o, 2+res_data_len);
        }

        if (fdset[1].revents & POLLPRI) {
            // got interrupt

            lseek(fdset[1].fd, 0, SEEK_SET);
            read(fdset[1].fd, buf, MAX_BUF);

            read_spi_reg(fd, EVT_REG, &evt_reg, 1);
            if (evt_reg & ALE_RX_DRDY_EVT) {
                // now read ALE RX chain

                // this event cleared in modem on read
                read_spi_reg(fd, ALE_RX_CHAIN_REG, read_data, ALE_TXRX_BUF_SIZE+1); // +1 due to duplicate first byte bug
                p32 = (int32_t *)&read_data[0];
                // syslog(LOG_INFO, "got ALE word 0x%x\n", *p32);
                memcpy(&cmdbuf_o[2], &read_data[1], ALE_TXRX_BUF_SIZE);
                cr = (uint16_t *)&cmdbuf_o[0];
                *cr = EVT_ALE_RXDATA;
                write_cmd(cmdbuf_o, 2+ALE_TXRX_BUF_SIZE);
            }

            if (evt_reg & ALE_TX_DONE_EVT) {
                syslog(LOG_INFO, "ALE tx complete\n");
                cr = (uint16_t *)&cmdbuf_o[0];
                *cr = EVT_ALE_TXDONE;
                write_cmd(cmdbuf_o, 2+0);
                evt_reg &= ~ALE_TX_DONE_EVT;
                write_spi_reg(fd, EVT_REG, &evt_reg, 1); // must explitly clear this	
            }

            if (evt_reg & TX_CHAIN_EMPT_EVT) {
                if (ringbuf_count(&tx_fifo) > 0) {
                    p32 = (int32_t *)&write_data[0];
                    for (i = 0; i < TXRX_BUF_SIZE; i+=4) {
                        val = 0;
                        if (ringbuf_read(&tx_fifo, &val)) {
                            tx_fifo_buffering = 1; // go back to buffering
                        }
                        *p32++ = (val << 8); // to 24-bits
                    }
                    // this event cleared in modem on write to tx chain
                    write_spi_reg(fd, TX_CHAIN_REG, write_data, TXRX_BUF_SIZE);
                }
            }
            if (evt_reg & TX_CHAIN_FULL_EVT) {
                // syslog(LOG_INFO,"TX FULL\n");

                // got enough, clear it
                tx_fifo_buffering = 0;

                // clear potential TX_DONE bit to avoid transmission until EMPTY received
                evt_reg &= ~TX_CHAIN_DONE_EVT;

                // this event cleared in modem automatically
            }

            if (evt_reg & RX_CHAIN_DRDY_EVT) {
                // now read RX chain
                // this event cleared in modem on read
                // read_spi_reg(fd, RX_CHAIN_REG, read_data, TXRX_BUF_SIZE+1);  // +1 due to duplicate first byte bug
                read_spi_reg(fd, RX_CHAIN_REG, (uint8_t *)netbuf, TXRX_BUF_SIZE+1);  // +1 due to duplicate first byte bug
				
                // // write new RX data into FIFO
                // p32 = (int32_t *)&read_data[1]; // start at 1 due to dup first byte bug!
                // for (i = 0; i < TXRX_BUF_SIZE; i+=4) {
                // 	// TODO: consider rounding instead of truncation!!!
                // 	val = (*p32 >> 8); // convert to 16-bit
                // 	if (ringbuf_write(&rx_fifo, val)) {
                // 		syslog(LOG_INFO,"error: RX FIFO FULL, dumping sample\n");
                // 	}
                // 	p32++;
                // }

                // check if it is time to send a packet
                // if (ringbuf_count(&rx_fifo) >= (NET_BUF_SIZE >> 1)) {
                // p16 = (int16_t *)&netbuf[0];
                // val = 0;
                // for (i = 0; i < NET_FRAME_SIZE; i+=2) {
                // if (ringbuf_read(&rx_fifo, &val)) {
                // syslog(LOG_INFO,"error: RX FIFO empty, writing 0\n");
                // }
                // *p16++ = val;
                // }

                // packet built, send it off
                // // len = NET_FRAME_SIZE;
                // len = TXRX_BUF_SIZE;
                // clientaddr.sin_port = htons((unsigned short)PORT_RXCHAIN);
                //    len = sendto(sockfd_txchain/*doesn't matter which */, 
                //    			netbuf, len, 0, (const struct sockaddr *)&clientaddr, clientlen);
                //    if (len < 0) {
                //        syslog(LOG_INFO, "%s: ERROR: in sendto\n", strerror(errno));
                //    }

                len = TXRX_BUF_SIZE;
                clientaddr.sin_port = htons((unsigned short)PORT_RXCHAIN);
                len = sendto(sockfd_txchain/*doesn't matter which */, 
                             &netbuf[1]/*due to dup first byte SPI bug*/, 
                             len, 0, (const struct sockaddr *)&clientaddr, clientlen);
                if (len < 0) {
                    syslog(LOG_INFO, "%s: ERROR: in sendto\n", strerror(errno));
                }
                // }
            }

            if (evt_reg & TX_CHAIN_DONE_EVT) {
                // tell link layer
                cr = (uint16_t *)&cmdbuf_o[0];
                *cr = EVT_TXDONE;
                write_cmd(cmdbuf_o, 2);

#if 0
                // syslog(LOG_INFO,"tx complete, grab 50 from %d\n", ringbuf_count(&tx_fifo));

                for (i = 0; i < TXRX_BUF_SIZE; i+=4) {
                    val = 0;
                    // Only if TX FIFO is more than 1/2 full ...
                    if (!tx_fifo_buffering) {
                        // syslog(LOG_INFO,"grab TX data for modem\n");
                        if (ringbuf_read(&tx_fifo, &val)) {
                            syslog(LOG_INFO,"warn: TX FIFO empty, writing 0\n");

                            // tell link layer
                            // cr = (uint16_t *)&cmdbuf_o[0];
                            // *cr = EVT_TXEMPT;
                            // write_cmd(cmdbuf_o, 2);
                            tx_fifo_buffering = 1; // go back to buffering
                        }
                    }
                    *p32++ = (val << 8); // to 24-bits
                }
                if (!tx_fifo_buffering) {
                    addr = 3; // TX chain
                    write_data[0] = addr | 0x80; // set write bit
                    write_spi(fd, write_data, 1);
                    p32 = (int32_t *)&write_data[0];
                    write_spi(fd, write_data, TXRX_BUF_SIZE);					
                }
#endif

                evt_reg &= ~TX_CHAIN_DONE_EVT;
                write_spi_reg(fd, EVT_REG, &evt_reg, 1); // must explitly clear this					
            }
        }

        if (fdset[2].revents & POLLIN) {
            len = recvfrom(sockfd_txchain, netbuf, NET_BUF_SIZE, 0,
                           (struct sockaddr *) &clientaddr, &clientlen);
            if (len < 0) {
                syslog(LOG_INFO, "%s: ERROR: in recvfrom\n", strerror(errno));
            }			
            // syslog(LOG_INFO, "recvfrom(): len=%d\n",len);

            // write new TX data into FIFO			
            p16 = (int16_t *)&netbuf[0];
            for (i = 0; i < len; i+=2) {
                if (ringbuf_write(&tx_fifo, *p16)) {
                    // syslog(LOG_INFO,"error: TX FIFO FULL, dumping sample\n");
                }
                p16++;
            }

            if (tx_fifo_buffering) {
                if (ringbuf_count(&tx_fifo) >= (TXRX_BUF_SIZE>1)) {
					
                    // we have enough to transmit a frame
                    // addr = 3; // TX chain
                    // write_data[0] = addr | 0x80; // set write bit
                    // write_spi(fd, write_data, 1);
                    p32 = (int32_t *)&write_data[0];
                    for (i = 0; i < TXRX_BUF_SIZE; i+=4) {
                        val = 0;
                        if (ringbuf_read(&tx_fifo, &val)) {
                            syslog(LOG_INFO,"BUG?\n");
                        }
                        *p32++ = (val << 8); // to 24-bits
                    }
                    // write_spi(fd, write_data, TXRX_BUF_SIZE);					
                    write_spi_reg(fd, TX_CHAIN_REG, write_data, TXRX_BUF_SIZE);
                }
            }
        }
    }

out:
    syslog(LOG_INFO, "frontend_port exiting...\n");
    gpio_fd_close(gpio_fd);
    close(fd);
    ringbuf_destroy(&tx_fifo);

    return ret;
}
