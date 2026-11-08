// The kernel's ceiling for local sockets, without Swift or any executor: N sender/receiver thread pairs over
// blocking sockets, each pair its own connection.
//
// Built and run by Tools/socket-ceiling; directly:
//     xcrun clang -O2 -o socket-ceiling Tools/lib/socket-ceiling.c
//     ./socket-ceiling PAIRS BYTES-PER-PAIR WRITE-SIZE [SOCKET-BUFFER-SIZE [u]]
//
// The fifth argument `u` uses a Unix-domain socketpair instead of loopback TCP. At most 256 pairs.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <sys/un.h>
static int sockbuf, useUnix;
static void sizeBuffers(int fd) { if (sockbuf) { setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sockbuf, sizeof sockbuf); setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sockbuf, sizeof sockbuf); } }

static long perConnection; static int chunk;
typedef struct { int fd; long bytes; } job;

static void *sender(void *arg) {
    job *j = arg; char *buf = malloc(chunk); memset(buf, 0x5A, chunk);
    long left = perConnection;
    while (left > 0) { ssize_t n = write(j->fd, buf, left < chunk ? left : chunk); if (n <= 0) { perror("write"); exit(1); } left -= n; }
    close(j->fd); free(buf); return NULL;
}
static void *receiver(void *arg) {
    job *j = arg; char *buf = malloc(chunk); long total = 0; ssize_t n;
    while ((n = read(j->fd, buf, chunk)) > 0) total += n;
    j->bytes = total; close(j->fd); free(buf); return NULL;
}
int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s PAIRS BYTES-PER-PAIR WRITE-SIZE [SOCKET-BUFFER-SIZE [u]]\n", argv[0]); return 2; }
    int pairs = atoi(argv[1]); perConnection = atol(argv[2]);
    if (pairs < 1 || pairs > 256) { fprintf(stderr, "PAIRS must be 1-256\n"); return 2; } chunk = atoi(argv[3]); sockbuf = argc > 4 ? atoi(argv[4]) : 0; useUnix = argc > 5 && argv[5][0] == 'u';
    pthread_t threads[512]; job jobs[512];
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < pairs; i++) {
        int sv[2]; if (useUnix) { socketpair(AF_UNIX, SOCK_STREAM, 0, sv); sizeBuffers(sv[0]); sizeBuffers(sv[1]); jobs[2*i] = (job){ sv[0], 0 }; jobs[2*i+1] = (job){ sv[1], 0 }; pthread_create(&threads[2*i], NULL, sender, &jobs[2*i]); pthread_create(&threads[2*i+1], NULL, receiver, &jobs[2*i+1]); continue; }
        int l = socket(AF_INET, SOCK_STREAM, 0); struct sockaddr_in a = { .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        bind(l, (struct sockaddr *)&a, sizeof a); listen(l, 4); socklen_t len = sizeof a; getsockname(l, (struct sockaddr *)&a, &len);
        int c = socket(AF_INET, SOCK_STREAM, 0); connect(c, (struct sockaddr *)&a, sizeof a); int s = accept(l, NULL, NULL); close(l); sizeBuffers(c); sizeBuffers(s);
        jobs[2*i] = (job){ c, 0 }; jobs[2*i+1] = (job){ s, 0 };
        pthread_create(&threads[2*i], NULL, sender, &jobs[2*i]); pthread_create(&threads[2*i+1], NULL, receiver, &jobs[2*i+1]);
    }
    long total = 0;
    for (int i = 0; i < 2*pairs; i++) pthread_join(threads[i], NULL);
    for (int i = 0; i < pairs; i++) total += jobs[2*i+1].bytes;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double s = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    printf("%d pairs: %.2f GB in %.1f ms: %.2f GB/s\n", pairs, total / 1e9, s * 1e3, total / s / 1e9);
}
