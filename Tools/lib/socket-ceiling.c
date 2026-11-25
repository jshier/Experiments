// The kernel's ceiling for local sockets, without Swift or any executor: N sender/receiver thread pairs over
// blocking sockets, each pair its own connection.
//
// Built and run by Tools/socket-ceiling; directly:
//     xcrun clang -O2 -o socket-ceiling Tools/lib/socket-ceiling.c
//     ./socket-ceiling PAIRS BYTES-PER-PAIR WRITE-SIZE [SOCKET-BUFFER-SIZE [u]]
//
// The fifth argument `u` uses a Unix-domain socketpair instead of loopback TCP. At most 256 pairs. Prints one line,
// tab-separated: pairs, bytes received in total, milliseconds, GB/s (10^9 bytes a second). Every call is checked: a
// failure prints the call and its error and exits 2, as does a transfer that comes up short.
#include <arpa/inet.h>
#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static int sockbuf, useUnix;
static long perConnection;
static int chunk;
typedef struct { int fd; long bytes; } job;

static void fail(const char *what) { perror(what); exit(2); }
static void check(int result, const char *what) { if (result < 0) fail(what); }

static void sizeBuffers(int fd) {
    if (!sockbuf) return;
    check(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sockbuf, sizeof sockbuf), "setsockopt(SO_SNDBUF)");
    check(setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sockbuf, sizeof sockbuf), "setsockopt(SO_RCVBUF)");
}

static void *sender(void *arg) {
    job *j = arg;
    char *buf = malloc(chunk);
    if (!buf) fail("malloc");
    memset(buf, 0x5A, chunk);
    long left = perConnection;
    while (left > 0) {
        ssize_t n = write(j->fd, buf, left < chunk ? left : chunk);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) fail("write");
        left -= n;
    }
    check(close(j->fd), "close");
    free(buf);
    return NULL;
}

static void *receiver(void *arg) {
    job *j = arg;
    char *buf = malloc(chunk);
    if (!buf) fail("malloc");
    long total = 0;
    for (;;) {
        ssize_t n = read(j->fd, buf, chunk);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) fail("read");
        if (n == 0) break;
        total += n;
    }
    j->bytes = total;
    check(close(j->fd), "close");
    free(buf);
    return NULL;
}

// How many descriptor numbers below `limit` are free: the open ones are listed by the kernel, wherever they are (a
// parent can leave some above this process's soft limit).
static rlim_t free_below(rlim_t limit) {
    static struct proc_fdinfo *fds;
    static int count = -1;
    if (count < 0) {
        int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
        if (bytes <= 0) fail("proc_pidinfo(PROC_PIDLISTFDS)");
        bytes += 16 * (int)sizeof *fds;
        fds = malloc((size_t)bytes);
        if (!fds) fail("malloc");
        bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds, bytes);
        if (bytes <= 0) fail("proc_pidinfo(PROC_PIDLISTFDS)");
        count = bytes / (int)sizeof *fds;
    }
    rlim_t used = 0;
    for (int i = 0; i < count; i++) used += (rlim_t)fds[i].proc_fd < limit;
    return limit - used;
}

// A whole positive number no larger than `max`, or exit 2.
static long number(const char *s, const char *what, long max) {
    char *end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno || end == s || *end || v < 1 || v > max) {
        fprintf(stderr, "%s must be a whole number from 1 to %ld, not '%s'\n", what, max, s);
        exit(2);
    }
    return v;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s PAIRS BYTES-PER-PAIR WRITE-SIZE [SOCKET-BUFFER-SIZE [u]]\n", argv[0]); return 2; }
    int pairs = (int)number(argv[1], "PAIRS", 256);
    perConnection = number(argv[2], "BYTES-PER-PAIR", LONG_MAX / 256);
    chunk = (int)number(argv[3], "WRITE-SIZE", INT_MAX);
    sockbuf = argc > 4 && strcmp(argv[4], "0") != 0 ? (int)number(argv[4], "SOCKET-BUFFER-SIZE", INT_MAX) : 0;
    useUnix = argc > 5 && argv[5][0] == 'u';
    signal(SIGPIPE, SIG_IGN);

    // New descriptors: two per pair, and a listening socket while a TCP pair connects (a socketpair has none). Each takes
    // the lowest free number, which must be below the soft limit; descriptors already open (inherited, at any number)
    // take some of those.
    struct rlimit limit;
    check(getrlimit(RLIMIT_NOFILE, &limit), "getrlimit(RLIMIT_NOFILE)");
    rlim_t wanted = 2 * (rlim_t)pairs + (useUnix ? 0 : 1), target = 0;
    while (free_below(target) < wanted) target++;
    // macOS gives a process only 25 descriptors whenever its soft limit is 26 to 50: step over that range.
    if (target > 25 && target < 51) target = 51;
    rlim_t effective = limit.rlim_cur > 25 && limit.rlim_cur < 51 ? 25 : limit.rlim_cur;
    if (free_below(effective) < wanted) {
        if (limit.rlim_max < target) {
            if (limit.rlim_max > 25 && limit.rlim_max < 51)
                fprintf(stderr, "%d pairs need a descriptor limit of %llu; the hard limit is %llu, and macOS allows only 25 "
                        "descriptors with a limit of 26 to 50 (raise the hard limit past 50, or use fewer pairs)\n",
                        pairs, (unsigned long long)target, (unsigned long long)limit.rlim_max);
            else
                fprintf(stderr, "%d pairs need a descriptor limit of %llu; the hard limit is %llu\n", pairs,
                        (unsigned long long)target, (unsigned long long)limit.rlim_max);
            return 2;
        }
        limit.rlim_cur = target;
        check(setrlimit(RLIMIT_NOFILE, &limit), "setrlimit(RLIMIT_NOFILE)");
    }

    pthread_t threads[512];
    job jobs[512];
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < pairs; i++) {
        int sender_fd, receiver_fd;
        if (useUnix) {
            int sv[2];
            check(socketpair(AF_UNIX, SOCK_STREAM, 0, sv), "socketpair");
            sender_fd = sv[0];
            receiver_fd = sv[1];
        } else {
            int l = socket(AF_INET, SOCK_STREAM, 0);
            check(l, "socket");
            struct sockaddr_in a = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
            check(bind(l, (struct sockaddr *)&a, sizeof a), "bind");
            check(listen(l, 4), "listen");
            socklen_t len = sizeof a;
            check(getsockname(l, (struct sockaddr *)&a, &len), "getsockname");
            sender_fd = socket(AF_INET, SOCK_STREAM, 0);
            check(sender_fd, "socket");
            check(connect(sender_fd, (struct sockaddr *)&a, sizeof a), "connect");
            receiver_fd = accept(l, NULL, NULL);
            check(receiver_fd, "accept");
            check(close(l), "close");
        }
        sizeBuffers(sender_fd);
        sizeBuffers(receiver_fd);
        jobs[2 * i] = (job){ sender_fd, 0 };
        jobs[2 * i + 1] = (job){ receiver_fd, 0 };
        if ((errno = pthread_create(&threads[2 * i], NULL, sender, &jobs[2 * i]))) fail("pthread_create");
        if ((errno = pthread_create(&threads[2 * i + 1], NULL, receiver, &jobs[2 * i + 1]))) fail("pthread_create");
    }
    long total = 0;
    for (int i = 0; i < 2 * pairs; i++) pthread_join(threads[i], NULL);
    for (int i = 0; i < pairs; i++) total += jobs[2 * i + 1].bytes;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    if (total != perConnection * pairs) {
        fprintf(stderr, "received %ld bytes of %ld\n", total, perConnection * pairs);
        return 2;
    }
    double s = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    printf("%d\t%ld\t%.1f\t%.2f\n", pairs, total, s * 1e3, total / s / 1e9);
    return 0;
}
