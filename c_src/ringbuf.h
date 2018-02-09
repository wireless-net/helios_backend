/* ringbuf.h ---
 *
 * Filename: ringbuf.h
 * Description:
 * Author: Devin Butterfield
 * Maintainer:
 * Created: Wed May 14 20:49:06 2014 (-0700)
 * Version:
 * Last-Updated: Wed Jul 23 22:55:41 2014 (-0700)
 *           By: Devin Butterfield
 *     Update #: 48
 * URL:
 * Keywords:
 * Compatibility:
 *
 */

/* Commentary:
 *
 *
 *
 */

/* Change Log:
 *
 *
 */

/* *This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 3, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth
 * Floor, Boston, MA 02110-1301, USA.
 */

/* Code: */

#ifndef __RINGBUF_H
#define __RINGBUF_H

typedef struct ringbuf {
    short *pbuf;
    int wridx;
    int rdidx;
    int length;
    int count;
} ringbuf_t;

int ringbuf_create(ringbuf_t *pringbuf, int len)
{
    /* empty is when wridx == rdidx */
    pringbuf->pbuf = (short *)malloc(sizeof(short)*len);
    if (pringbuf->pbuf == NULL) {
        return -1;
    }
    pringbuf->wridx = 0;
    pringbuf->rdidx = 0;
    pringbuf->length = len;
    pringbuf->count = 0;
    memset(pringbuf->pbuf, 0, sizeof(short)*len);
    return 0;
}

int ringbuf_destroy(ringbuf_t *pringbuf)
{
    free(pringbuf->pbuf);
    return 0;
}

int ringbuf_length(ringbuf_t *pringbuf)
{
    return pringbuf->length;
}

int ringbuf_count(ringbuf_t *pringbuf)
{
    return pringbuf->count;
}

int ringbuf_isempty(ringbuf_t *pringbuf) 
{
    if (pringbuf->rdidx == pringbuf->wridx) {
        return 1;
    }
    return 0;
}

/* returns -1 on overrun */
int ringbuf_write(ringbuf_t *pringbuf, short val)
{
    /* put it in the buffer */
    pringbuf->pbuf[pringbuf->wridx++] = val;

    if (pringbuf->wridx > (pringbuf->length-1)) {
        pringbuf->wridx = 0; // wrapped
    }

    if (pringbuf->wridx == pringbuf->rdidx) {
        /* The rule for this circular buffer is to keep read
         * at least 1 ahead of write, since write == read is
         * reserved for empty. So, we actually do consider
         * this an over-write case and must dump the next item
         * in the list. */

        /* do the dump */
        pringbuf->rdidx++;
    
        if (pringbuf->rdidx > (pringbuf->length-1)) {
            pringbuf->rdidx = 0; // wrapped
        }
        return -1;
    }
    pringbuf->count++;
    return 0;
}

/* return -1 if empty */
int ringbuf_read(ringbuf_t *pringbuf, short *val)
{
    if (pringbuf->rdidx == pringbuf->wridx) {
        return -1;
    }

    /* grab it */
    *val = pringbuf->pbuf[pringbuf->rdidx++];
    if (pringbuf->rdidx > (pringbuf->length-1)) {
        pringbuf->rdidx = 0; /* wrapped */
    }
    pringbuf->count--;
    return 0;
}

short *ringbuf_buf(ringbuf_t *pringbuf)
{
    return pringbuf->pbuf;
}

#endif/* __RINGBUF_H */

/* ringbuf.h ends here */
