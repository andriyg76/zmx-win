#ifndef ZMX_WIN_CSHIM_H
#define ZMX_WIN_CSHIM_H

/* The termios, ioctl and environment names zmx uses, for Windows. win/cshim.zig implements the functions:
   termios carries the console modes, and the ioctls answer for the console and the session's pseudo
   console. */

#include <stdlib.h>
#include <stdio.h>
#include <io.h>

typedef unsigned int tcflag_t;
typedef unsigned char cc_t;

#define NCCS 20
#define VQUIT 1
#define VLNEXT 15
#define VMIN 16
#define VTIME 17
#define _POSIX_VDISABLE 0

struct termios {
    tcflag_t c_iflag;
    tcflag_t c_oflag;
    tcflag_t c_cflag;
    tcflag_t c_lflag;
    cc_t c_cc[NCCS];
    unsigned int zmx_in_mode;
    unsigned int zmx_out_mode;
    unsigned int zmx_in_cp;
    unsigned int zmx_out_cp;
    unsigned int zmx_raw;
};

struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};

#define TCSANOW 0
#define TCSADRAIN 1
#define TCSAFLUSH 2
#define TCIFLUSH 0
#define TCOFLUSH 1
#define TCIOFLUSH 2

#define TIOCGWINSZ 0x5413
#define TIOCSWINSZ 0x5414
#define TIOCOUTQ 0x5411
#define TIOCGPGRP 0x540F
#define FIONREAD 0x541B

int ioctl(int fd, unsigned long request, void *arg);
int tcgetattr(int fd, struct termios *t);
int tcsetattr(int fd, int action, const struct termios *t);
int tcflush(int fd, int queue);
void cfmakeraw(struct termios *t);
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);

#endif
