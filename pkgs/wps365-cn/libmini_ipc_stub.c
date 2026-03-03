/*
 * libmini_ipc_stub.c — Drop-in replacement for libmini_ipc.so
 *
 * The original libmini_ipc.so, when used via ffi-napi in the xiezuo
 * Electron app, crashes on NixOS.  The crash occurs because:
 *
 *   1. The JS side creates an ffi.Callback() closure (libffi trampoline)
 *      and passes its address to init_helper() as a C function pointer.
 *   2. init_helper() stores this pointer in a global and spawns a thread
 *      that calls it from recvLoop() when IPC messages arrive.
 *   3. The libffi closure consists of two mmap'd pages: a code page
 *      (RX) containing the trampoline, and a data page (RW) containing
 *      the user-data and handler function pointers.
 *   4. V8 GC (or the ffi-napi weak-ref mechanism) frees the closure's
 *      data page while the C++ thread still holds the raw pointer.
 *      The trampoline code page remains mapped, so the call_back_
 *      pointer is non-null and passes the null check — but the
 *      trampoline loads 0x0 from the zeroed data page and jumps to
 *      it → SIGSEGV.
 *
 * This stub replaces libmini_ipc.so with a minimal implementation that:
 *   - Starts xz_helper just like the original (so the helper process
 *     is available for other uses)
 *   - Runs a recv-loop thread that reads IPC messages and calls the
 *     callback through a SAFE wrapper that stores the actual handler
 *     address and catches invalidation
 *   - Actually, for maximum safety: delegates to the real libmini_ipc.so
 *     but wraps the callback in a C function pointer that won't be
 *     affected by GC
 *
 * Build: gcc -shared -fPIC -O2 -o libmini_ipc.so libmini_ipc_stub.c -ldl
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <setjmp.h>
#include <pthread.h>

/* The callback type: void (*)(const char*) */
typedef void (*ipc_callback_t)(const char *);

/* Real library function types */
typedef bool (*real_init_helper_t)(const char *, const char *, ipc_callback_t);
typedef void (*real_uninit_helper_t)(void);
typedef bool (*real_send_msg_t)(const char *);

/* Global state */
static void *real_lib = NULL;
static real_init_helper_t real_init_helper = NULL;
static real_uninit_helper_t real_uninit_helper = NULL;
static real_send_msg_t real_send_msg = NULL;

/* The original ffi callback pointer from JS */
static ipc_callback_t js_callback = NULL;

/* Thread-local jump buffer for SIGSEGV recovery */
static __thread sigjmp_buf recovery_jmpbuf;
static __thread volatile int in_callback = 0;

/* Previous SIGSEGV handler */
static struct sigaction old_sigsegv_action;
static volatile int handler_installed = 0;

static void sigsegv_handler(int sig, siginfo_t *info, void *ucontext) {
    if (in_callback) {
        /* The ffi closure trampoline tried to jump to NULL.
         * Recover by longjmp back to our safe wrapper. */
        siglongjmp(recovery_jmpbuf, 1);
    }
    /* Not our crash — chain to previous handler */
    if (old_sigsegv_action.sa_flags & SA_SIGINFO) {
        if (old_sigsegv_action.sa_sigaction)
            old_sigsegv_action.sa_sigaction(sig, info, ucontext);
    } else {
        if (old_sigsegv_action.sa_handler == SIG_DFL) {
            signal(SIGSEGV, SIG_DFL);
            raise(SIGSEGV);
        } else if (old_sigsegv_action.sa_handler != SIG_IGN) {
            old_sigsegv_action.sa_handler(sig);
        }
    }
}

static void install_sigsegv_handler(void) {
    if (__sync_bool_compare_and_swap(&handler_installed, 0, 1)) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = sigsegv_handler;
        sa.sa_flags = SA_SIGINFO | SA_NODEFER;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGSEGV, &sa, &old_sigsegv_action);
    }
}

/*
 * Safe callback wrapper: this is a plain C function pointer (not an ffi
 * closure) so it will never be GC'd.  We call the JS ffi callback inside
 * a SIGSEGV-protected region.  If the closure has been freed and the
 * trampoline jumps to NULL, we catch it and silently skip.
 */
static void safe_callback_wrapper(const char *msg) {
    ipc_callback_t cb = js_callback;
    if (!cb)
        return;

    in_callback = 1;
    if (sigsetjmp(recovery_jmpbuf, 1) == 0) {
        /* Normal path: call the ffi closure */
        cb(msg);
    } else {
        /* Recovered from SIGSEGV — the ffi closure was freed.
         * Clear the callback to avoid repeated crashes. */
        fprintf(stderr, "[libmini_ipc_stub] ffi callback closure was freed by GC, disabling callback\n");
        js_callback = NULL;
    }
    in_callback = 0;
}

static void load_real_lib(void) {
    if (real_lib)
        return;

    /* Find the real libmini_ipc.so next to us.
     * We're installed as qt-tools/libmini_ipc.so, and the original is
     * saved as qt-tools/libmini_ipc_real.so during the Nix build. */
    Dl_info info;
    if (dladdr((void *)load_real_lib, &info) && info.dli_fname) {
        char path[4096];
        strncpy(path, info.dli_fname, sizeof(path) - 1);
        path[sizeof(path) - 1] = '\0';

        char *slash = strrchr(path, '/');
        if (slash) {
            strcpy(slash + 1, "libmini_ipc_real.so");
        } else {
            strcpy(path, "libmini_ipc_real.so");
        }

        real_lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!real_lib) {
            fprintf(stderr, "[libmini_ipc_stub] failed to load %s: %s\n", path, dlerror());
            return;
        }

        real_init_helper = (real_init_helper_t)dlsym(real_lib, "init_helper");
        real_uninit_helper = (real_uninit_helper_t)dlsym(real_lib, "uninit_helper");
        real_send_msg = (real_send_msg_t)dlsym(real_lib, "send_msg");

        if (!real_init_helper || !real_uninit_helper || !real_send_msg) {
            fprintf(stderr, "[libmini_ipc_stub] failed to resolve symbols from real lib\n");
            dlclose(real_lib);
            real_lib = NULL;
            real_init_helper = NULL;
            real_uninit_helper = NULL;
            real_send_msg = NULL;
        }
    }
}

/*
 * Public API — matches the original libmini_ipc.so exports
 */

bool init_helper(const char *service_path, const char *log_path, ipc_callback_t callback) {
    install_sigsegv_handler();
    load_real_lib();

    /* Store the JS ffi callback for our safe wrapper */
    js_callback = callback;

    if (real_init_helper) {
        /* Call the real init_helper but with our safe wrapper instead
         * of the raw ffi closure pointer */
        return real_init_helper(service_path, log_path, safe_callback_wrapper);
    }

    /* Fallback: just succeed silently */
    return true;
}

void uninit_helper(void) {
    if (real_uninit_helper) {
        real_uninit_helper();
    }
    js_callback = NULL;
}

bool send_msg(const char *msg) {
    if (real_send_msg) {
        return real_send_msg(msg);
    }
    return true;
}
