/* conscat OUT [SECONDS]: takes the console (TIOCCONS on a pty) and appends what processes write to /dev/console to OUT. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>
#include <util.h>
int main(int argc, char **argv)
{
	int m, s, on = 1, off = 0; char buf[4096];
	if (argc < 2) return 2;
	int secs = argc > 2 ? atoi(argv[2]) : 0;
	if (openpty(&m, &s, NULL, NULL, NULL) != 0) { perror("openpty"); return 1; }
	if (ioctl(s, TIOCCONS, &on) != 0) { perror("TIOCCONS"); return 1; }
	int o = open(argv[1], O_WRONLY | O_CREAT | O_APPEND, 0644);
	time_t end = time(NULL) + secs;
	for (;;) {
		fd_set r; struct timeval tv = { 1, 0 };
		FD_ZERO(&r); FD_SET(m, &r);
		if (select(m + 1, &r, NULL, NULL, &tv) > 0) { ssize_t n = read(m, buf, sizeof buf); if (n > 0) (void)!write(o, buf, n); }
		if (secs && time(NULL) >= end) break;
	}
	ioctl(s, TIOCCONS, &off);
	return 0;
}
