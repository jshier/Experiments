// What one Apple silicon core can do: instruction latency and throughput, load-to-use latency by working set,
// and read/store bandwidth by thread count. Plain C and inline assembly, no Swift.
//
// Built and run by Tools/cpu-probe; directly:
//     xcrun clang -O2 -mcpu=apple-m1 -o cpu-probe Tools/lib/cpu-probe.c
//     ./cpu-probe freq | insn [NAME...] | latency [SIZE...] | bandwidth read|store BYTES-PER-THREAD THREADS...
//
// Every thread asks for QOS_CLASS_USER_INTERACTIVE, so it runs on a performance core when one is free.
//
// Cycles: user space can't read the cycle counter, so `freq` measures the clock with a dependent chain of scalar
// `add`s (one cycle of latency on every Apple core), and `insn` and `latency` convert times with it. The
// calibration is printed: a core that changes its clock between calibration and measurement shows up as a vector
// `add` that isn't 2 cycles.
#include <arm_neon.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/qos.h>
#include <time.h>

static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) * 1e-9; }
static void interactive(void) { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0); }

// MARK: - Instructions

// Each instruction is timed twice. Latency: one register, every instruction depending on the last (`.rept 32`).
// Throughput: 16 independent chains (`v0`–`v15`, or `x9`–`x15` for scalar code: 7), enough to cover 4 cycles of
// latency at 4 a cycle; with fewer, an instruction's rate reads as chains ÷ latency (8 chains made every
// 3-cycle instruction look like 2.7 a cycle). Operands that don't carry the chain are `v20`–`v23`; tables are `v24`–`v27`. In a throughput form,
// `\r` is the chain's register number (an assembler `.irp`).

#define CLOBBER_V "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", \
    "v20", "v21", "v22", "v23", "v24", "v25", "v26", "v27"
#define CLOBBER_X "x9", "x10", "x11", "x12", "x13", "x14", "x15"

// The timed loops are generated per instruction below (one function each) from these two templates.
#define LATENCY_LOOP(BODY) \
    static void lat_##BODY(long n) { \
        __asm__ volatile("movi v20.16b, #3\nmovi v21.16b, #5\nmovi v22.16b, #7\nmovi v23.16b, #9\n" \
                         "movi v24.16b, #1\nmovi v25.16b, #2\nmovi v26.16b, #3\nmovi v27.16b, #4\n" \
                         "movi v0.16b, #1\nmov x9, #1\nmov x16, #3\n" \
                         "1:\n.rept 32\n" BODY##_L "\n.endr\nsubs %x[n], %x[n], #1\nb.ne 1b\n" \
                         : [n] "+r"(n) : : CLOBBER_V, CLOBBER_X, "x16", "cc"); \
    } \
    static void tput_##BODY(long n) { \
        __asm__ volatile("movi v20.16b, #3\nmovi v21.16b, #5\nmovi v22.16b, #7\nmovi v23.16b, #9\n" \
                         "movi v24.16b, #1\nmovi v25.16b, #2\nmovi v26.16b, #3\nmovi v27.16b, #4\n" \
                         ".irp r,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15\nmovi v\\r\\().16b, #1\n.endr\n" \
                         ".irp r,9,10,11,12,13,14,15\nmov x\\r, #1\n.endr\nmov x16, #3\n" \
                         /* Four rounds written out: LLVM's assembler doesn't substitute an .irp nested in .rept. */ \
                         "1:\n" BODY##_T "\n" BODY##_T "\n" BODY##_T "\n" BODY##_T "\nsubs %x[n], %x[n], #1\nb.ne 1b\n" \
                         : [n] "+r"(n) : : CLOBBER_V, CLOBBER_X, "x16", "cc"); \
    }

#define V16(X) ".irp r,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15\n" X "\n.endr"
#define X7(X) ".irp r,9,10,11,12,13,14,15\n" X "\n.endr"

// Scalar.
#define s_add_L "add x9, x9, #1"
#define s_add_T X7("add x\\r, x\\r, #1")
#define s_mul_L "mul x9, x9, x16"
#define s_mul_T X7("mul x\\r, x\\r, x16")
#define s_crc32x_L "crc32x w9, w9, x16"
#define s_crc32x_T X7("crc32x w\\r, w\\r, x16")
// Vector, 16 bytes.
#define v_add_L "add v0.16b, v0.16b, v20.16b"
#define v_add_T V16("add v\\r\\().16b, v\\r\\().16b, v20.16b")
#define v_eor_L "eor v0.16b, v0.16b, v20.16b"
#define v_eor_T V16("eor v\\r\\().16b, v\\r\\().16b, v20.16b")
#define v_eor3_L "eor3 v0.16b, v0.16b, v20.16b, v21.16b"
#define v_eor3_T V16("eor3 v\\r\\().16b, v\\r\\().16b, v20.16b, v21.16b")
#define v_bcax_L "bcax v0.16b, v0.16b, v20.16b, v21.16b"
#define v_bcax_T V16("bcax v\\r\\().16b, v\\r\\().16b, v20.16b, v21.16b")
#define v_shl_L "shl v0.16b, v0.16b, #1"
#define v_shl_T V16("shl v\\r\\().16b, v\\r\\().16b, #1")
#define v_zip1_L "zip1 v0.16b, v0.16b, v20.16b"
#define v_zip1_T V16("zip1 v\\r\\().16b, v\\r\\().16b, v20.16b")
#define v_uzp1_L "uzp1 v0.16b, v0.16b, v20.16b"
#define v_uzp1_T V16("uzp1 v\\r\\().16b, v\\r\\().16b, v20.16b")
#define v_ext_L "ext v0.16b, v0.16b, v20.16b, #3"
#define v_ext_T V16("ext v\\r\\().16b, v\\r\\().16b, v20.16b, #3")
#define v_rev32_L "rev32 v0.16b, v0.16b"
#define v_rev32_T V16("rev32 v\\r\\().16b, v\\r\\().16b")
#define v_umaxv_L "umaxv b0, v0.16b"
#define v_umaxv_T V16("umaxv b\\r, v\\r\\().16b")
// Table lookups: the chain goes through the indices (`tbl`) or the destination (`tbx`), whose bytes out of range
// are kept.
#define v_tbl1_L "tbl v0.16b, {v24.16b}, v0.16b"
#define v_tbl1_T V16("tbl v\\r\\().16b, {v24.16b}, v\\r\\().16b")
#define v_tbl2_L "tbl v0.16b, {v24.16b, v25.16b}, v0.16b"
#define v_tbl2_T V16("tbl v\\r\\().16b, {v24.16b, v25.16b}, v\\r\\().16b")
#define v_tbl3_L "tbl v0.16b, {v24.16b, v25.16b, v26.16b}, v0.16b"
#define v_tbl3_T V16("tbl v\\r\\().16b, {v24.16b, v25.16b, v26.16b}, v\\r\\().16b")
#define v_tbl4_L "tbl v0.16b, {v24.16b, v25.16b, v26.16b, v27.16b}, v0.16b"
#define v_tbl4_T V16("tbl v\\r\\().16b, {v24.16b, v25.16b, v26.16b, v27.16b}, v\\r\\().16b")
#define v_tbx1_L "tbx v0.16b, {v24.16b}, v20.16b"
#define v_tbx1_T V16("tbx v\\r\\().16b, {v24.16b}, v20.16b")
#define v_tbx2_L "tbx v0.16b, {v24.16b, v25.16b}, v20.16b"
#define v_tbx2_T V16("tbx v\\r\\().16b, {v24.16b, v25.16b}, v20.16b")
#define v_tbx3_L "tbx v0.16b, {v24.16b, v25.16b, v26.16b}, v20.16b"
#define v_tbx3_T V16("tbx v\\r\\().16b, {v24.16b, v25.16b, v26.16b}, v20.16b")
#define v_tbx4_L "tbx v0.16b, {v24.16b, v25.16b, v26.16b, v27.16b}, v20.16b"
#define v_tbx4_T V16("tbx v\\r\\().16b, {v24.16b, v25.16b, v26.16b, v27.16b}, v20.16b")
#define v_tbx4i_L "tbx v0.16b, {v24.16b, v25.16b, v26.16b, v27.16b}, v0.16b"
#define v_tbx4i_T V16("tbx v\\r\\().16b, {v24.16b, v25.16b, v26.16b, v27.16b}, v\\r\\().16b")
// Multiplies, accumulates, dot products.
#define v_usra_L "usra v0.2d, v20.2d, #3"
#define v_usra_T V16("usra v\\r\\().2d, v20.2d, #3")
#define v_mul_L "mul v0.4s, v0.4s, v20.4s"
#define v_mul_T V16("mul v\\r\\().4s, v\\r\\().4s, v20.4s")
#define v_umull_L "umull v0.2d, v0.2s, v20.2s"
#define v_umull_T V16("umull v\\r\\().2d, v\\r\\().2s, v20.2s")
#define v_udot_L "udot v0.4s, v20.16b, v21.16b"
#define v_udot_T V16("udot v\\r\\().4s, v20.16b, v21.16b")
#define v_fmla_L "fmla v0.4s, v20.4s, v21.4s"
#define v_fmla_T V16("fmla v\\r\\().4s, v20.4s, v21.4s")
// Cryptography.
#define v_pmull_L "pmull v0.1q, v0.1d, v20.1d"
#define v_pmull_T V16("pmull v\\r\\().1q, v\\r\\().1d, v20.1d")
#define v_pmull2_L "pmull2 v0.1q, v0.2d, v20.2d"
#define v_pmull2_T V16("pmull2 v\\r\\().1q, v\\r\\().2d, v20.2d")
#define v_aese_L "aese v0.16b, v20.16b"
#define v_aese_T V16("aese v\\r\\().16b, v20.16b")
#define v_aesmc_L "aesmc v0.16b, v0.16b"
#define v_aesmc_T V16("aesmc v\\r\\().16b, v\\r\\().16b")
#define v_aesround_L "aese v0.16b, v20.16b\naesmc v0.16b, v0.16b"
#define v_aesround_T V16("aese v\\r\\().16b, v20.16b\naesmc v\\r\\().16b, v\\r\\().16b")
#define v_sha256h_L "sha256h q0, q20, v21.4s"
#define v_sha256h_T V16("sha256h q\\r, q20, v21.4s")
#define v_sha512h_L "sha512h q0, q20, v21.2d"
#define v_sha512h_T V16("sha512h q\\r, q20, v21.2d")
#define v_sha1c_L "sha1c q0, s20, v21.4s"
#define v_sha1c_T V16("sha1c q\\r, s20, v21.4s")

#define INSNS(X) \
    X(s_add, "add (scalar)", 1, 1) X(s_mul, "mul (scalar)", 1, 1) X(s_crc32x, "crc32x", 1, 1) \
    X(v_add, "add.16b", 0, 1) X(v_eor, "eor.16b", 0, 1) X(v_eor3, "eor3", 0, 1) X(v_bcax, "bcax", 0, 1) \
    X(v_shl, "shl.16b", 0, 1) X(v_zip1, "zip1.16b", 0, 1) X(v_uzp1, "uzp1.16b", 0, 1) X(v_ext, "ext.16b", 0, 1) \
    X(v_rev32, "rev32.16b", 0, 1) X(v_umaxv, "umaxv.16b", 0, 1) \
    X(v_tbl1, "tbl 1 reg", 0, 1) X(v_tbl2, "tbl 2 regs", 0, 1) X(v_tbl3, "tbl 3 regs", 0, 1) X(v_tbl4, "tbl 4 regs", 0, 1) \
    X(v_tbx1, "tbx 1 reg", 0, 1) X(v_tbx2, "tbx 2 regs", 0, 1) X(v_tbx3, "tbx 3 regs", 0, 1) X(v_tbx4, "tbx 4 regs", 0, 1) \
    X(v_tbx4i, "tbx 4 regs (via indices)", 0, 1) \
    X(v_usra, "usra.2d", 0, 1) X(v_mul, "mul.4s", 0, 1) X(v_umull, "umull.2d", 0, 1) X(v_udot, "udot.4s", 0, 1) \
    X(v_fmla, "fmla.4s", 0, 1) X(v_pmull, "pmull", 0, 1) X(v_pmull2, "pmull2", 0, 1) X(v_aese, "aese", 0, 1) \
    X(v_aesmc, "aesmc", 0, 1) X(v_aesround, "aese+aesmc pair", 0, 2) X(v_sha256h, "sha256h", 0, 1) \
    X(v_sha512h, "sha512h", 0, 1) X(v_sha1c, "sha1c", 0, 1)

#define DEFINE(ID, NAME, SCALAR, PER) LATENCY_LOOP(ID)
INSNS(DEFINE)

typedef struct { const char *id, *name; int scalar, perInsn; void (*lat)(long), (*tput)(long); } probe;
#define ENTRY(ID, NAME, SCALAR, PER) {#ID, NAME, SCALAR, PER, lat_##ID, tput_##ID},
static const probe probes[] = { INSNS(ENTRY) };

// Best of `runs` timings of `f(n)`, in seconds.
static double best(void (*f)(long), long n, int runs) {
    double b = 1e9;
    for (int i = 0; i < runs; i++) {
        double t0 = now();
        f(n);
        double t = now() - t0;
        if (t < b) b = t;
    }
    return b;
}

static double ghz(void) {
    lat_s_add(1000000); // Warm up: let the core reach its clock.
    long n = 4000000;   // 32 adds an iteration: 128 M, about 40 ms.
    return 32.0 * n / best(lat_s_add, n, 7) * 1e-9;
}

static int cmd_insn(int argc, char **argv) {
    double f = ghz();
    printf("# clock %.3f GHz (dependent scalar add = 1 cycle)\n", f);
    printf("instruction\tlatency_cycles\tper_cycle\n");
    for (size_t i = 0; i < sizeof probes / sizeof probes[0]; i++) {
        const probe *p = &probes[i];
        if (argc > 0) {
            int wanted = 0;
            for (int a = 0; a < argc; a++) wanted |= strcmp(argv[a], p->id) == 0 || strcmp(argv[a], p->name) == 0;
            if (!wanted) continue;
        }
        long n = 1000000;
        p->lat(n / 10);
        double lat = best(p->lat, n, 5) * f * 1e9 / (32.0 * n);
        // Throughput: 4 rounds of 16 chains (7 for scalar) an iteration, one form each (`perInsn` instructions).
        double perIter = 4.0 * (p->scalar ? 7 : 16);
        double tput = perIter * n / (best(p->tput, n, 5) * f * 1e9);
        // Both per form: a pair (`aese+aesmc`) reports the pair's latency and pairs per cycle.
        printf("%s\t%.2f\t%.2f\n", p->name, lat, tput);
    }
    return 0;
}

// MARK: - Load-to-use latency

static long parse_size(const char *s) {
    char *end;
    double v = strtod(s, &end);
    switch (*end) {
        case 'k': case 'K': v *= 1024; break;
        case 'm': case 'M': v *= 1024 * 1024; break;
        case 'g': case 'G': v *= 1024.0 * 1024 * 1024; break;
    }
    return (long)v;
}

// Page-aligned memory (`aligned_alloc` returns NULL unless the size is a multiple of the alignment).
static void *page_alloc(long bytes) {
    void *p = aligned_alloc(16384, (bytes + 16383) & ~16383L);
    if (!p) { fprintf(stderr, "out of memory (%ld bytes)\n", bytes); exit(1); }
    return p;
}

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint64_t next_random(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

// A pointer chase through every 128-byte line of `bytes`, in a random cyclic order (Sattolo's shuffle), so no
// prefetcher can predict the next line.
static double chase_ns(long bytes) {
    const long line = 128;
    long lines = bytes / line;
    if (lines < 2) lines = 2;
    char *buffer = page_alloc(lines * line);
    long *order = malloc(lines * sizeof(long));
    for (long i = 0; i < lines; i++) order[i] = i;
    for (long i = lines - 1; i > 0; i--) {
        long j = next_random() % i;
        long t = order[i]; order[i] = order[j]; order[j] = t;
    }
    for (long i = 0; i < lines; i++) *(void **)(buffer + order[i] * line) = buffer + order[(i + 1) % lines] * line;
    void **p = (void **)buffer;
    long steps = 20000000;
    for (long i = 0; i < lines * 2; i++) p = *p; // Warm the caches and TLBs.
    double b = 1e9;
    for (int run = 0; run < 3; run++) {
        double t0 = now();
        for (long i = 0; i < steps; i++) p = *p;
        double t = now() - t0;
        if (t < b) b = t;
    }
    __asm__ volatile("" : : "r"(p));
    free(order);
    free(buffer);
    return b / steps * 1e9;
}

static int cmd_latency(int argc, char **argv) {
    static const char *defaults[] = { "16K", "32K", "64K", "128K", "256K", "512K", "1M", "2M", "4M", "8M", "12M",
                                      "16M", "24M", "32M", "48M", "64M", "128M", "256M", "512M" };
    if (argc == 0) { argc = sizeof defaults / sizeof defaults[0]; argv = (char **)defaults; }
    double f = ghz();
    printf("# clock %.3f GHz; one pointer per 128-byte line, random order\n", f);
    printf("working_set\tns\tcycles\n");
    for (int i = 0; i < argc; i++) {
        double ns = chase_ns(parse_size(argv[i]));
        printf("%s\t%.2f\t%.1f\n", argv[i], ns, ns * f);
    }
    return 0;
}

// MARK: - Bandwidth

typedef struct {
    long bytes, passes;
    int store;
    _Atomic int *ready, *go;
    double seconds;
} worker;

// Reads (128 bytes a step, four `eor` accumulators) or stores (128 bytes of one register a step) the buffer,
// `passes` times.
static void *bandwidth_worker(void *arg) {
    worker *w = arg;
    interactive();
    uint8_t *buffer = page_alloc(w->bytes);
    memset(buffer, 1, w->bytes);
    uint8x16_t a0 = vdupq_n_u8(0), a1 = a0, a2 = a0, a3 = a0;
    // macOS has no pthread barriers: count in, then spin until the main thread says go.
    atomic_fetch_add(w->ready, 1);
    while (!atomic_load(w->go)) {}
    double t0 = now();
    for (long pass = 0; pass < w->passes; pass++) {
        if (w->store) {
            uint8x16x4_t v = { { vdupq_n_u8(pass), vdupq_n_u8(pass), vdupq_n_u8(pass), vdupq_n_u8(pass) } };
            for (long i = 0; i < w->bytes; i += 128) {
                vst1q_u8_x4(buffer + i, v);
                vst1q_u8_x4(buffer + i + 64, v);
            }
            __asm__ volatile("" : : "r"(buffer) : "memory");
        } else {
            for (long i = 0; i < w->bytes; i += 128) {
                uint8x16x4_t x = vld1q_u8_x4(buffer + i), y = vld1q_u8_x4(buffer + i + 64);
                a0 = veorq_u8(a0, veorq_u8(x.val[0], y.val[0]));
                a1 = veorq_u8(a1, veorq_u8(x.val[1], y.val[1]));
                a2 = veorq_u8(a2, veorq_u8(x.val[2], y.val[2]));
                a3 = veorq_u8(a3, veorq_u8(x.val[3], y.val[3]));
            }
        }
    }
    w->seconds = now() - t0;
    uint8x16_t sum = veorq_u8(veorq_u8(a0, a1), veorq_u8(a2, a3));
    __asm__ volatile("" : : "w"(sum));
    free(buffer);
    return NULL;
}

static int cmd_bandwidth(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: cpu-probe bandwidth read|store BYTES-PER-THREAD THREADS...\n"); return 2; }
    int store = strcmp(argv[0], "store") == 0;
    long bytes = parse_size(argv[1]) & ~127L;
    // About 4 GB moved per thread (at least 3 passes), so a run takes 50–100 ms per thread at memory speed.
    long passes = (4L << 30) / bytes;
    if (passes < 3) passes = 3;
    printf("threads\tbytes_per_thread\tGB_per_s_total\tGB_per_s_per_thread\n");
    for (int a = 2; a < argc; a++) {
        int threads = atoi(argv[a]);
        if (threads < 1 || threads > 256) { fprintf(stderr, "THREADS must be 1-256\n"); return 2; }
        double bestRate = 0;
        for (int run = 0; run < 3; run++) {
            _Atomic int ready = 0, go = 0;
            worker *workers = calloc(threads, sizeof(worker));
            pthread_t *ids = calloc(threads, sizeof(pthread_t));
            for (int t = 0; t < threads; t++) {
                workers[t] = (worker){ bytes, passes, store, &ready, &go, 0 };
                pthread_create(&ids[t], NULL, bandwidth_worker, &workers[t]);
            }
            while (atomic_load(&ready) < threads) {}
            atomic_store(&go, 1);
            for (int t = 0; t < threads; t++) pthread_join(ids[t], NULL);
            // The slowest thread's own time: buffer setup and teardown aren't counted.
            double slowest = 0;
            for (int t = 0; t < threads; t++) if (workers[t].seconds > slowest) slowest = workers[t].seconds;
            double rate = (double)threads * bytes * passes / slowest * 1e-9;
            if (rate > bestRate) bestRate = rate;
            free(workers);
            free(ids);
        }
        printf("%d\t%ld\t%.1f\t%.1f\n", threads, bytes, bestRate, bestRate / threads);
    }
    return 0;
}

int main(int argc, char **argv) {
    interactive();
    if (argc < 2) goto usage;
    if (strcmp(argv[1], "freq") == 0) { printf("%.3f\n", ghz()); return 0; }
    if (strcmp(argv[1], "insn") == 0) return cmd_insn(argc - 2, argv + 2);
    if (strcmp(argv[1], "latency") == 0) return cmd_latency(argc - 2, argv + 2);
    if (strcmp(argv[1], "bandwidth") == 0) return cmd_bandwidth(argc - 2, argv + 2);
usage:
    fprintf(stderr, "usage: cpu-probe freq | insn [NAME...] | latency [SIZE...] | bandwidth read|store BYTES THREADS...\n");
    return 2;
}
