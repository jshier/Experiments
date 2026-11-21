// Memory probe for Tools/probe (run it through `Tools/probe mem`). Three measurements, each printed as a TSV table:
//
//   latency     load-to-use latency by pointer chase: one pointer per 128-byte line (Apple silicon's line size),
//               lines visited in a random order, working sets from 16 KB up to 512 MB (1 GB when the Mac has
//               16 GB or more). Reported in ns and in cycles of a dependent-`add` calibration.
//   bandwidth   one thread's read bandwidth (128-bit loads into four `eor` accumulators) and write bandwidth
//               (128-bit stores) by working set, about 4 GB moved per measurement, best of 3.
//   threads     read bandwidth summed over N threads, each reading its own buffer (256 MB, less on Macs with
//               less memory: at most 1/8 of memory in all), best of 3; N from `-t 1,2,4,...`.
//
// usage: mem latency|bandwidth|threads [-q] [-t LIST] [-m MAX_MB]
//   -q quick (shorter measurements), -t thread counts, -m largest latency working set in MB.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/qos.h>
#include <sys/sysctl.h>
#include <arm_neon.h>

static inline uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static uint64_t rng = 0x9E3779B97F4A7C15;
static uint64_t next_random(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }
static int quick;

static uint64_t sysctl_u64(const char *name) {
    uint64_t value = 0; size_t size = sizeof value;
    if (sysctlbyname(name, &value, &size, 0, 0) != 0) return 0;
    if (size == 4) return (uint32_t)value;
    return value;
}

static void *allocate(size_t bytes) {
    void *p = aligned_alloc(16384, bytes);
    if (!p) { fprintf(stderr, "error: couldn't allocate %zu MB\n", bytes >> 20); exit(1); }
    return p;
}

// Clock of this core: a dependent chain of 1-cycle adds, best of 7, after the warm-up the caller did.
static double clock_ghz(void) {
    double best = 1e30;
    long iters = 1000000;
    for (int r = 0; r < 7; r++) {
        uint64_t t = now();
        register long n __asm__("x0") = iters;
        __asm__ volatile("mov x1, #0\n1:\n\t"
                         "add x1, x1, #1\n\tadd x1, x1, #1\n\tadd x1, x1, #1\n\tadd x1, x1, #1\n\t"
                         "add x1, x1, #1\n\tadd x1, x1, #1\n\tadd x1, x1, #1\n\tadd x1, x1, #1\n\t"
                         "add x1, x1, #1\n\tadd x1, x1, #1\n\tadd x1, x1, #1\n\tadd x1, x1, #1\n\t"
                         "add x1, x1, #1\n\tadd x1, x1, #1\n\tadd x1, x1, #1\n\tadd x1, x1, #1\n\t"
                         "subs x0, x0, #1\n\tb.ne 1b" : "+r"(n) :: "x1", "cc");
        double ns = (double)(now() - t);
        if (ns < best) best = ns;
    }
    return (double)iters * 16 / best;
}

static void warm_up(int ms) { uint64_t until = now() + (uint64_t)ms * 1000000; while (now() < until) clock_ghz(); }

// ns per dependent load, chasing pointers through `bytes`, one per 128-byte line in a random cycle.
static double chase(size_t bytes) {
    size_t lines = bytes / 128;
    char *buf = allocate(bytes);
    size_t *order = malloc(lines * sizeof *order);
    if (!order) { fprintf(stderr, "error: out of memory\n"); exit(1); }
    for (size_t i = 0; i < lines; i++) order[i] = i;
    for (size_t i = lines - 1; i > 0; i--) { size_t j = next_random() % (i + 1); size_t t = order[i]; order[i] = order[j]; order[j] = t; }
    for (size_t i = 0; i < lines; i++) *(void **)(buf + order[i] * 128) = buf + order[(i + 1) % lines] * 128;
    free(order);
    void **p = (void **)buf;
    // Warm the caches and TLB: the whole cycle twice (capped where the set is far beyond the caches anyway).
    size_t warm = lines * 2 < 2000000 ? lines * 2 : 2000000;
    for (size_t i = 0; i < warm; i++) p = *p;
    // Size the timed loops to about 150 ms (40 quick) from a first short one.
    size_t steps = 1000000;
    uint64_t t = now();
    for (size_t i = 0; i < steps; i++) p = *p;
    double estimate = (double)(now() - t) / steps;
    double target = quick ? 40e6 : 150e6;
    steps = (size_t)(target / estimate);
    if (steps < 1000000) steps = 1000000;
    double best = 1e30;
    for (int r = 0; r < 3; r++) {
        t = now();
        for (size_t i = 0; i < steps; i++) p = *p;
        double ns = (double)(now() - t) / steps;
        if (ns < best) best = ns;
    }
    if (p == 0) puts("");
    free(buf);
    return best;
}

static uint8x16_t read_pass(const uint8_t *buf, size_t bytes) {
    uint8x16_t a = vdupq_n_u8(0), b = a, c = a, d = a;
    for (size_t i = 0; i < bytes; i += 64) {
        a = veorq_u8(a, vld1q_u8(buf + i));
        b = veorq_u8(b, vld1q_u8(buf + i + 16));
        c = veorq_u8(c, vld1q_u8(buf + i + 32));
        d = veorq_u8(d, vld1q_u8(buf + i + 48));
    }
    return veorq_u8(veorq_u8(a, b), veorq_u8(c, d));
}

static void write_pass(uint8_t *buf, size_t bytes, uint8x16_t v) {
    for (size_t i = 0; i < bytes; i += 64) {
        vst1q_u8(buf + i, v); vst1q_u8(buf + i + 16, v); vst1q_u8(buf + i + 32, v); vst1q_u8(buf + i + 48, v);
    }
}

static volatile uint8_t sink;

static void bandwidth(size_t bytes, double *read_gbs, double *write_gbs) {
    uint8_t *buf = allocate(bytes);
    memset(buf, 1, bytes);
    size_t total = (size_t)(quick ? 1 : 4) << 30;  // bytes moved per measurement
    size_t passes = total / bytes; if (passes < 4) passes = 4;
    double best_read = 1e30, best_write = 1e30;
    for (int r = 0; r < 3; r++) {
        uint64_t t = now(); uint8x16_t acc = vdupq_n_u8(0);
        for (size_t p = 0; p < passes; p++) acc = veorq_u8(acc, read_pass(buf, bytes));
        double ns = (double)(now() - t); sink = vgetq_lane_u8(acc, 0);
        if (ns < best_read) best_read = ns;
        t = now();
        for (size_t p = 0; p < passes; p++) write_pass(buf, bytes, vdupq_n_u8((uint8_t)p));
        ns = (double)(now() - t);
        if (ns < best_write) best_write = ns;
    }
    sink = buf[bytes / 2];
    *read_gbs = (double)bytes * passes / best_read;
    *write_gbs = (double)bytes * passes / best_write;
    free(buf);
}

static _Atomic int ready, go;
struct job { uint8_t *buf; size_t bytes; int passes; int fill; uint8_t out; };
static void *worker(void *arg) {
    struct job *j = arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    if (j->fill) { memset(j->buf, j->out, j->bytes); return 0; }
    atomic_fetch_add(&ready, 1);
    while (!atomic_load(&go)) {}
    uint8x16_t acc = vdupq_n_u8(0);
    for (int p = 0; p < j->passes; p++) acc = veorq_u8(acc, read_pass(j->buf, j->bytes));
    j->out = vgetq_lane_u8(acc, 0);
    return 0;
}

#define MAXTHREADS 256
static struct job jobs[MAXTHREADS];

static double threads_read(int n) {
    pthread_t th[MAXTHREADS];
    double best = 0;
    for (int r = 0; r < (quick ? 2 : 3); r++) {
        atomic_store(&ready, 0); atomic_store(&go, 0);
        for (int i = 0; i < n; i++) { jobs[i].fill = 0; pthread_create(&th[i], 0, worker, &jobs[i]); }
        while (atomic_load(&ready) < n) {}
        uint64_t t = now();
        atomic_store(&go, 1);
        for (int i = 0; i < n; i++) pthread_join(th[i], 0);
        double ns = (double)(now() - t);
        double gbs = (double)jobs[0].bytes * jobs[0].passes * n / ns;
        if (gbs > best) best = gbs;
    }
    return best;
}

static void usage(void) {
    fprintf(stderr, "usage: mem latency|bandwidth|threads [-q] [-t 1,2,4,...] [-m MAX_MB]\n");
    exit(2);
}

int main(int argc, char **argv) {
    if (argc < 2) usage();
    const char *what = argv[1];
    const char *thread_list = 0;
    size_t max_mb = 0;
    int opt;
    optind = 2;
    while ((opt = getopt(argc, argv, "qt:m:")) != -1) {
        switch (opt) {
            case 'q': quick = 1; break;
            case 't': thread_list = optarg; break;
            case 'm': max_mb = strtoull(optarg, 0, 10); break;
            default: usage();
        }
    }
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    uint64_t memsize = sysctl_u64("hw.memsize");
    int ncpu = (int)sysctl_u64("hw.ncpu");

    if (!strcmp(what, "latency")) {
        // Largest working set: 1 GB where memory is 16 GB or more, else 512 MB, and never over 1/16 of memory.
        size_t limit = max_mb ? max_mb << 20 : (memsize >= ((uint64_t)16 << 30) ? (size_t)1 << 30 : (size_t)512 << 20);
        while (limit > memsize / 16 && limit > ((size_t)64 << 20)) limit /= 2;
        warm_up(quick ? 150 : 400);
        size_t sizes[] = {16<<10, 32<<10, 64<<10, 128<<10, 192<<10, 256<<10, 512<<10, 1<<20, 2<<20, 4<<20, 8<<20, 12<<20, 16<<20,
                          24<<20, 32<<20, 48<<20, 64<<20, 96<<20, 128<<20, 256<<20, 512<<20, (size_t)1<<30};
        double lo = 1e30, hi = 0;
        printf("working_set_KB\tlatency_ns\tlatency_cycles\n");
        for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
            if (sizes[i] > limit) break;
            double ns = chase(sizes[i]);
            double ghz = clock_ghz();  // right after the chase: the clock it ran at, as near as we can tell
            if (ghz < lo) lo = ghz;
            if (ghz > hi) hi = ghz;
            printf("%zu\t%.2f\t%.1f\n", sizes[i] >> 10, ns, ns * ghz);
            fflush(stdout);
        }
        fprintf(stderr, "clock: %.3f to %.3f GHz (each row's cycles use the clock measured right after it)\n", lo, hi);
    } else if (!strcmp(what, "bandwidth")) {
        size_t sizes[] = {32<<10, 128<<10, 256<<10, 1<<20, 4<<20, 16<<20, 32<<20, 64<<20, 128<<20, 256<<20};
        warm_up(quick ? 150 : 400);
        printf("working_set_KB\tread_GBs\twrite_GBs\n");
        for (size_t i = 0; i < sizeof sizes / sizeof *sizes; i++) {
            if (sizes[i] > memsize / 16) break;
            double r, w; bandwidth(sizes[i], &r, &w);
            printf("%zu\t%.1f\t%.1f\n", sizes[i] >> 10, r, w);
            fflush(stdout);
        }
    } else if (!strcmp(what, "threads")) {
        int counts[MAXTHREADS], ncounts = 0, most = 0;
        if (thread_list) {
            for (char *s = (char *)thread_list; *s && ncounts < MAXTHREADS; ) {
                int c = (int)strtol(s, &s, 10);
                if (c < 1 || c > MAXTHREADS) usage();
                counts[ncounts++] = c;
                if (*s == ',') s++; else if (*s) usage();
            }
        } else {
            for (int c = 1; c <= ncpu && c <= MAXTHREADS; c *= 2) counts[ncounts++] = c;
            if (counts[ncounts - 1] != ncpu && ncpu <= MAXTHREADS) counts[ncounts++] = ncpu;
        }
        for (int i = 0; i < ncounts; i++) if (counts[i] > most) most = counts[i];
        // 256 MB per thread, halved until all the buffers together are at most 1/8 of memory (32 MB at least).
        size_t bytes = (size_t)256 << 20;
        while (bytes * most > memsize / 8 && bytes > ((size_t)32 << 20)) bytes /= 2;
        fprintf(stderr, "threads: %zu MB per thread, %zu MB in all\n", bytes >> 20, (bytes * most) >> 20);
        pthread_t th[MAXTHREADS];
        for (int i = 0; i < most; i++) {
            jobs[i].buf = allocate(bytes); jobs[i].bytes = bytes; jobs[i].passes = 4; jobs[i].fill = 1; jobs[i].out = (uint8_t)i;
            pthread_create(&th[i], 0, worker, &jobs[i]);  // fill (and fault in) every buffer in parallel
        }
        for (int i = 0; i < most; i++) pthread_join(th[i], 0);
        printf("threads\tread_GBs_total\tper_thread_MB\n");
        for (int i = 0; i < ncounts; i++) {
            printf("%d\t%.1f\t%zu\n", counts[i], threads_read(counts[i]), bytes >> 20);
            fflush(stdout);
        }
        for (int i = 0; i < most; i++) free(jobs[i].buf);
    } else {
        usage();
    }
    return 0;
}
