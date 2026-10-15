/* setsid escapee: the grandchild leaves the session, SAYS whether setsid()
 * succeeded (on the inherited stdout), then sleeps holding the pipe. */
#include <stdio.h>
#include <unistd.h>
int main(void)
{
	if (fork())
		return 0;
	pid_t s = setsid();
	printf("setsid=%s sid=%ld pid=%ld\n", s == getpid() ? "ok" : "failed", (long)getsid(0), (long)getpid());
	fflush(stdout);
	sleep(37);
	return 0;
}
