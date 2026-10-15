/* fork-hopper: the child of fs-supervise's child calls setsid(), then
 * keeps forking and exiting so no pid lives long (review S4). If any
 * instance is still alive after 5 s it writes the marker file argv[1]. */
#include <stdio.h>
#include <time.h>
#include <unistd.h>
int main(int argc, char **argv)
{
	time_t t0 = time(0);
	if (argc < 2 || fork())
		return 0;
	setsid();
	for (;;) {
		pid_t p = fork();
		if (p > 0)
			_exit(0);
		if (p < 0)
			continue;
		if (time(0) - t0 > 5) {
			FILE *f = fopen(argv[1], "w");
			if (f) { fputs("survived\n", f); fclose(f); }
			_exit(0);
		}
	}
}
