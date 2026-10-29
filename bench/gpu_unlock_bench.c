/* SPDX-License-Identifier: GPL-2.0-only
 * gpu_unlock_bench — single-file issue-rate + correctness probe for the
 * Ada (AD102/AD103) tensor-core unlock, for Linux and Windows.
 *
 * Dependencies: the standard C runtime plus the NVIDIA driver at runtime
 * (nvcuda.dll / libcuda.so.1, loaded dynamically so a missing driver yields
 * a readable error instead of a loader abort). Both probe cubins are
 * embedded; no CUDA toolkit, no Python, no files next to the binary.
 *
 *   mma table : diagnostics/bench/mma_bench.cu        (timing, 7 modes)
 *   verify    : tensor_modes_issue.cu via driver API  (timing + all-cell check)
 *
 * Formulas and launch geometry are copied verbatim from those tools so
 * results are directly comparable with the Linux reference runs.
 * Output: unlock_bench_<timestamp>.txt in the current directory.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#define LOADLIB(n) LoadLibraryA(n)
#define GETSYM GetProcAddress
#define LIBNAME(n) n
typedef HMODULE HMODULELIB;
#else
#include <dlfcn.h>
#define LOADLIB(n) dlopen(n, RTLD_NOW)
#define GETSYM dlsym
#define LIBNAME(n) n
typedef void *HMODULELIB;
#endif

typedef int CUresult;
typedef unsigned long long CUdeviceptr;
typedef struct { void *p; } *CUmodule;
typedef struct { void *p; } *CUfunction;
typedef struct { void *p; } *CUcontext;
typedef struct { void *p; } *CUevent;

static CUresult (*p_cuInit)(unsigned);
static CUresult (*p_cuDeviceGetCount)(int *);
static CUresult (*p_cuDeviceGet)(int *, int);
static CUresult (*p_cuDeviceGetName)(char *, int, int);
static CUresult (*p_cuDeviceComputeCapability)(int *, int *, int);
static CUresult (*p_cuDriverGetVersion)(int *);
static CUresult (*p_cuCtxCreate)(CUcontext *, unsigned, int);
static CUresult (*p_cuCtxDestroy)(CUcontext);
static CUresult (*p_cuCtxSynchronize)(void);
static CUresult (*p_cuModuleLoadData)(CUmodule *, const void *);
static CUresult (*p_cuModuleGetFunction)(CUfunction *, CUmodule, const char *);
static CUresult (*p_cuMemAlloc)(CUdeviceptr *, size_t);
static CUresult (*p_cuMemFree)(CUdeviceptr);
static CUresult (*p_cuMemcpyDtoH)(void *, CUdeviceptr, size_t);
static CUresult (*p_cuEventCreate)(CUevent *, unsigned);
static CUresult (*p_cuEventRecord)(CUevent, void *);
static CUresult (*p_cuEventSynchronize)(CUevent);
static CUresult (*p_cuEventElapsedTime)(float *, CUevent, CUevent);
static CUresult (*p_cuEventDestroy)(CUevent);
static CUresult (*p_cuLaunchKernel)(CUfunction, unsigned, unsigned, unsigned,
                                    unsigned, unsigned, unsigned, unsigned,
                                    void *, void **, void *);
static CUresult (*p_cuGetErrorString)(CUresult, char **);

#define CHECK(call) do { CUresult r_ = (call); if (r_) { \
    char *s_ = NULL; if (p_cuGetErrorString) p_cuGetErrorString(r_, &s_); \
    fprintf(stderr, "\nFAIL %s: CUDA %d %s\n", #call, r_, s_ ? s_ : ""); \
    fprintf(stderr, "hint: check `nvidia-smi`; this probe needs an Ada (sm_89+) " \
                    "NVIDIA GPU and driver >= 515 with the CUDA driver library.\n"); \
    return 2; } } while (0)

#include "cubin_embed.h"

#define BLOCKS 1056
#define THREADS 256
#define WARPS (BLOCKS * THREADS / 32)
#define CHAINS 8
#define CELLS (BLOCKS * THREADS)
#define WMMA_FWI (8192.0 * CHAINS)
#define FP8_FWI  (8192.0 * CHAINS)
#define DP4A_FWI (8.0 * 32 * 32)
#define FFMA_FWI (2.0 * 32 * 32)

struct mma_mode { const char *label; const char *sym; double fwk; };
static const struct mma_mode mma_modes[] = {
    { "f16/f16 ", "_Z9bench_mmaI6__halfS0_EvyPf", WMMA_FWI },
    { "f16/f32 ", "_Z9bench_mmaI6__halffEvyPf",   WMMA_FWI },
    { "bf16/f32", "_Z9bench_mmaI13__nv_bfloat16fEvyPf", WMMA_FWI },
    { "s8/s32  ", "_Z9bench_mmaIaiEvyPf",         WMMA_FWI },
    { "fp8/e4m3", "_Z9bench_fp8yPf",              FP8_FWI  },
    { "dp4a    ", "_Z10bench_dp4ayPf",            DP4A_FWI },
    { "ffma    ", "_Z10bench_ffmayPf",            FFMA_FWI },
};

struct vfy_mode { const char *label; const char *sym; int k; int integer; };
static const struct vfy_mode vfy_modes[] = {
    { "f16_f32", "bench_f16_f32", 16, 0 },
    { "tf32   ", "bench_tf32",     8, 0 },
    { "u4_s32 ", "bench_u4",      64, 1 },
};

static double tflops(unsigned long long iters, double fwk, float ms)
{
    return (double)WARPS * (double)iters * fwk / ((double)ms * 1e9);
}

int main(int argc, char **argv)
{
    unsigned long long iters = 20000;
    int reps = 3;
    if (argc > 1 && (!strcmp(argv[1], "-h") || !strcmp(argv[1], "--help"))) {
        printf("usage: %s [iterations] [reps<=100]\n"
               "  writes unlock_bench_<timestamp>.txt to the current directory\n"
               "  needs: NVIDIA driver (nvcuda.dll / libcuda.so.1), Ada or newer GPU\n",
               argv[0]);
        return 0;
    }
    if (argc > 1) iters = strtoull(argv[1], NULL, 10);
    if (argc > 2) reps = atoi(argv[2]);
    if (!iters || reps < 1 || reps > 100) {
        fprintf(stderr, "usage: %s [positive iterations] [reps 1..100]\n", argv[0]);
        return 2;
    }

    HMODULELIB lib = LOADLIB(LIBNAME(
#ifdef _WIN32
        "nvcuda.dll"
#else
        "libcuda.so.1"
#endif
    ));
    if (!lib) {
#ifdef _WIN32
        fprintf(stderr,
            "\nERROR: cannot load nvcuda.dll (GetLastError=%lu).\n"
            "  -> The NVIDIA graphics driver is not installed or its CUDA\n"
            "     component is missing. Install the current driver from\n"
            "     https://www.nvidia.com/Download/index.aspx and retry.\n",
            GetLastError());
#else
        fprintf(stderr,
            "\nERROR: cannot dlopen libcuda.so.1: %s\n"
            "  -> The NVIDIA kernel driver/userspace library is not present.\n"
            "     Check `nvidia-smi` and that the matching nvidia driver\n"
            "     packages are installed (this tool does NOT bundle drivers).\n",
            dlerror());
#endif
        return 1;
    }
#define BIND(n, f) do { *(void **)&p_##n = (void *)GETSYM(lib, f); \
    if (!p_##n) *(void **)&p_##n = (void *)GETSYM(lib, f "_v2"); } while (0)
    BIND(cuInit, "cuInit"); BIND(cuDeviceGetCount, "cuDeviceGetCount");
    BIND(cuDeviceGet, "cuDeviceGet"); BIND(cuDeviceGetName, "cuDeviceGetName");
    BIND(cuDeviceComputeCapability, "cuDeviceComputeCapability");
    BIND(cuDriverGetVersion, "cuDriverGetVersion");
    BIND(cuCtxCreate, "cuCtxCreate"); BIND(cuCtxDestroy, "cuCtxDestroy");
    BIND(cuCtxSynchronize, "cuCtxSynchronize");
    BIND(cuModuleLoadData, "cuModuleLoadData");
    BIND(cuModuleGetFunction, "cuModuleGetFunction");
    BIND(cuMemAlloc, "cuMemAlloc"); BIND(cuMemFree, "cuMemFree");
    BIND(cuMemcpyDtoH, "cuMemcpyDtoH");
    BIND(cuEventCreate, "cuEventCreate"); BIND(cuEventRecord, "cuEventRecord");
    BIND(cuEventSynchronize, "cuEventSynchronize");
    BIND(cuEventElapsedTime, "cuEventElapsedTime");
    BIND(cuEventDestroy, "cuEventDestroy");
    BIND(cuLaunchKernel, "cuLaunchKernel");
    BIND(cuGetErrorString, "cuGetErrorString");
    {
        const char *missing = NULL;
        if (!p_cuInit) missing = "cuInit";
        else if (!p_cuLaunchKernel) missing = "cuLaunchKernel";
        else if (!p_cuModuleLoadData) missing = "cuModuleLoadData";
        if (missing) {
            fprintf(stderr,
                "\nERROR: driver library lacks '%s' - installed driver is too old.\n"
                "  This probe needs a CUDA-capable driver >= 515 (Ada support).\n",
                missing);
            return 1;
        }
    }

    char gpu_name[128] = "?";
    int drv_ver = 0, dev = 0, major = 0, minor = 0, count = 0;
    {
        CUresult r = p_cuInit(0);
        if (r) {
            char *s = NULL;
            if (p_cuGetErrorString) p_cuGetErrorString(r, &s);
            fprintf(stderr,
                "\nERROR: cuInit failed: CUDA %d %s\n"
                "  -> No usable CUDA device: is the GPU visible in nvidia-smi,\n"
                "     and are you booting in the state you want to measure?\n",
                r, s ? s : "");
            return 1;
        }
    }
    CHECK(p_cuDeviceGetCount(&count));
    if (!count) { fprintf(stderr, "\nERROR: no CUDA devices enumerated.\n"); return 1; }
    CHECK(p_cuDeviceGet(&dev, 0));
    CHECK(p_cuDeviceGetName(gpu_name, sizeof gpu_name, dev));
    CHECK(p_cuDeviceComputeCapability(&major, &minor, dev));
    if (p_cuDriverGetVersion) p_cuDriverGetVersion(&drv_ver);
    if (major < 8 || (major == 8 && minor < 9)) {
        fprintf(stderr,
            "\nERROR: device 0 is sm_%d%d; embedded cubins target sm_89 (Ada).\n"
            "  On a multi-GPU machine this probe measures only device 0.\n", major, minor);
        return 1;
    }

    CUcontext ctx = NULL;
    CHECK(p_cuCtxCreate(&ctx, 0, dev));
    CUmodule mod_mma = NULL, mod_vfy = NULL;
    {
        CUresult r = p_cuModuleLoadData(&mod_mma, mma_cubin);
        if (r) {
            char *s = NULL;
            p_cuGetErrorString(r, &s);
            fprintf(stderr,
                "\nERROR: loading embedded mma cubin failed: CUDA %d %s\n"
                "  -> driver API %d.%d may predate sm_89 cubin loading (need >= 515).\n",
                r, s ? s : "", drv_ver / 1000, drv_ver % 1000);
            return 2;
        }
        r = p_cuModuleLoadData(&mod_vfy, vfy_cubin);
        if (r) {
            char *s = NULL;
            p_cuGetErrorString(r, &s);
            fprintf(stderr, "\nERROR: loading verification cubin: CUDA %d %s\n", r, s ? s : "");
            return 2;
        }
    }
    CUdeviceptr sink = 0;
    CHECK(p_cuMemAlloc(&sink, CELLS * 4));

    char stamp[32];
    time_t t = time(NULL);
    strftime(stamp, sizeof stamp, "%Y%m%d_%H%M%S", localtime(&t));
    char fname[64];
    snprintf(fname, sizeof fname, "unlock_bench_%s.txt", stamp);
    FILE *fp = fopen(fname, "wb");
    if (!fp) {
        fprintf(stderr, "WARNING: cannot write '%s' (%s); printing to console only\n",
                fname, strerror(errno));
        fp = stderr;
    }
#define PRT(...) do { fprintf(fp, __VA_ARGS__); fprintf(stderr, __VA_ARGS__); } while (0)

    PRT("=== GPU unlock issue-rate probe (embedded cubins) ===\n");
    PRT("time          : %s", ctime(&t));
    PRT("gpu           : %s (sm_%d%d, device 0 of %d)\n", gpu_name, major, minor, count);
    PRT("driver API    : %d.%d\n", drv_ver / 1000, drv_ver % 1000);
    PRT("cubin mma sha : %s\n", MMA_CUBIN_SHA);
    PRT("cubin vfy sha : %s\n", VFY_CUBIN_SHA);
    PRT("grid          : blocks=%d threads=%d warps=%d iters=%llu reps=%d\n",
        BLOCKS, THREADS, WARPS, iters, reps);
    PRT("reference     : Linux baseline 4090D unlocked fp8=589.4 s8=589.9 "
        "f16f32=295.2 bf16=295.1 ffma=70.7 dp4a=146.6 TF/s\n");
    PRT("                (stock/half rates would be fp8~300 f16f32~158 bf16~155)\n\n");

    PRT("%-9s %10s  runs\n", "mode", "best TF/s");
    double fp8_best = 0.0, f16f32_best = 0.0, s8_best = 0.0;
    for (size_t i = 0; i < sizeof mma_modes / sizeof mma_modes[0]; i++) {
        CUfunction fn = NULL;
        CHECK(p_cuModuleGetFunction(&fn, mod_mma, mma_modes[i].sym));
        unsigned long long it = iters;
        void *params[2] = { &it, &sink };
        CUevent start, stop;
        double best = 0.0;
        char runs[128] = "";
        CHECK(p_cuEventCreate(&start, 0));
        CHECK(p_cuEventCreate(&stop, 0));
        for (int r = 0; r < reps; r++) {
            CHECK(p_cuLaunchKernel(fn, BLOCKS, 1, 1, THREADS, 1, 1, 0, NULL, params, NULL));
            CHECK(p_cuCtxSynchronize());
            CHECK(p_cuEventRecord(start, NULL));
            CHECK(p_cuLaunchKernel(fn, BLOCKS, 1, 1, THREADS, 1, 1, 0, NULL, params, NULL));
            CHECK(p_cuEventRecord(stop, NULL));
            CHECK(p_cuEventSynchronize(stop));
            float ms = 0.0f;
            CHECK(p_cuEventElapsedTime(&ms, start, stop));
            double v = tflops(iters, mma_modes[i].fwk, ms);
            if (v > best) best = v;
            snprintf(runs + strlen(runs), sizeof runs - strlen(runs),
                     r ? " / %.1f" : "%.1f", v);
        }
        CHECK(p_cuEventDestroy(start));
        CHECK(p_cuEventDestroy(stop));
        PRT("%-9s %10.1f  %s\n", mma_modes[i].label, best, runs);
        if (strstr(mma_modes[i].label, "fp8")) fp8_best = best;
        if (strstr(mma_modes[i].label, "f16/f32")) f16f32_best = best;
        if (strstr(mma_modes[i].label, "s8/")) s8_best = best;
    }

    PRT("\n%-9s %10s  %10s  expected/cells\n", "mode", "best Top/s", "mismatches");
    int vfy_ok = 1;
    for (size_t i = 0; i < sizeof vfy_modes / sizeof vfy_modes[0]; i++) {
        CUfunction fn = NULL;
        CHECK(p_cuModuleGetFunction(&fn, mod_vfy, vfy_modes[i].sym));
        unsigned long long it = iters;
        void *params[2] = { &it, &sink };
        long long expected = 4LL * CHAINS * (long long)iters * vfy_modes[i].k;
        double ops = (double)WARPS * (double)iters * CHAINS * (16.0 * 8.0 * vfy_modes[i].k * 2.0);
        CUevent start, stop;
        double best = 0.0;
        CHECK(p_cuEventCreate(&start, 0));
        CHECK(p_cuEventCreate(&stop, 0));
        CHECK(p_cuLaunchKernel(fn, BLOCKS, 1, 1, THREADS, 1, 1, 0, NULL, params, NULL));
        CHECK(p_cuCtxSynchronize());
        for (int r = 0; r < reps; r++) {
            CHECK(p_cuEventRecord(start, NULL));
            CHECK(p_cuLaunchKernel(fn, BLOCKS, 1, 1, THREADS, 1, 1, 0, NULL, params, NULL));
            CHECK(p_cuEventRecord(stop, NULL));
            CHECK(p_cuEventSynchronize(stop));
            float ms = 0.0f;
            CHECK(p_cuEventElapsedTime(&ms, start, stop));
            double v = ops / ((double)ms * 1e9);
            if (v > best) best = v;
        }
        CHECK(p_cuEventDestroy(start));
        CHECK(p_cuEventDestroy(stop));
        long long mismatches = 0;
        if (vfy_modes[i].integer) {
            int *host = malloc(CELLS * sizeof(int));
            if (!host) { fprintf(stderr, "OOM\n"); return 2; }
            CHECK(p_cuMemcpyDtoH(host, sink, CELLS * sizeof(int)));
            for (int c = 0; c < CELLS; c++) if ((long long)host[c] != expected) mismatches++;
            free(host);
        } else {
            float *host = malloc(CELLS * sizeof(float));
            if (!host) { fprintf(stderr, "OOM\n"); return 2; }
            CHECK(p_cuMemcpyDtoH(host, sink, CELLS * sizeof(float)));
            for (int c = 0; c < CELLS; c++) if (host[c] != (float)expected) mismatches++;
            free(host);
        }
        PRT("%-9s %10.1f  %10lld  %lld/%d\n", vfy_modes[i].label, best, mismatches,
            expected, CELLS);
        if (mismatches) vfy_ok = 0;
    }

    PRT("\n=== VERDICT ===\n");
    if (fp8_best >= 500.0 && f16f32_best >= 250.0)
        PRT("UNLOCKED: fp8 %.1f and f16/f32 %.1f TF/s are at full rate (2x stock).\n",
            fp8_best, f16f32_best);
    else if (fp8_best <= 380.0 && f16f32_best <= 210.0)
        PRT("STOCK: fp8 %.1f and f16/f32 %.1f TF/s are at half rate - unlock NOT active.\n",
            fp8_best, f16f32_best);
    else
        PRT("INDETERMINATE: fp8 %.1f, f16/f32 %.1f, s8 %.1f - check clocks/power\n"
            "  (Linux: nvidia-smi -q; Windows: Task Manager GPU) and rerun idle.\n",
            fp8_best, f16f32_best, s8_best);
    if (!vfy_ok) PRT("WARNING: cell verification mismatches - driver rejected the path?\n");
    PRT("result file   : %s\n", fname);
    if (fp != stderr) fclose(fp);
    p_cuMemFree(sink);
    p_cuCtxDestroy(ctx);
    return 0;
}
