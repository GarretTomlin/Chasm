#pragma once
/* engine/loader.h — dynamic script loader via dlopen/dlsym/dlclose.
 *
 * The engine binary is compiled once. The script is compiled to a shared
 * library (.dylib / .so) and loaded at runtime. On hot-reload the old
 * library is closed and the new one is opened in-place without restarting
 * the engine process.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "chasm_rt.h"

/* ---- Paths ------------------------------------------------------------ */
#if defined(__APPLE__)
#  define CHASM_SCRIPT_EXT      ".dylib"
#else
#  define CHASM_SCRIPT_EXT      ".so"
#endif
#define CHASM_RELOAD_SENTINEL   "/tmp/chasm_reload_ready"

/* Read the dylib path from the sentinel file (written by the CLI).
 * Returns 0 on success, -1 on failure. buf must be at least PATH_MAX bytes. */
static int chasm_read_sentinel(char *buf, size_t bufsz) {
    FILE *f = fopen(CHASM_RELOAD_SENTINEL, "r");
    if (!f) return -1;
    size_t n = fread(buf, 1, bufsz - 1, f);
    fclose(f);
    buf[n] = '\0';
    /* strip trailing newline */
    while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r')) buf[--n] = '\0';
    return n > 0 ? 0 : -1;
}

/* ---- Function-pointer typedefs --------------------------------------- */
typedef void (*chasm_module_init_fn)   (ChasmCtx *);
typedef void (*chasm_on_tick_fn)       (ChasmCtx *, double);
typedef void (*chasm_on_draw_fn)       (ChasmCtx *);
typedef void (*chasm_on_init_fn)       (ChasmCtx *);
typedef void (*chasm_on_unload_fn)     (ChasmCtx *);
typedef void (*chasm_reload_migrate_fn)(ChasmCtx *);

/* ---- No-op stubs for optional symbols -------------------------------- */
static void chasm_loader_noop_ctx(ChasmCtx *ctx) { (void)ctx; }

/* ---- ChasmLoader struct ---------------------------------------------- */
typedef struct {
    void                   *handle;
    chasm_module_init_fn    module_init;
    chasm_on_tick_fn        on_tick;
    chasm_on_draw_fn        on_draw;
    chasm_on_init_fn        on_init;
    chasm_on_unload_fn      on_unload;
    chasm_reload_migrate_fn reload_migrate;
} ChasmLoader;

/* ---- Internal: resolve symbols from an open handle ------------------- */
static int chasm_loader_resolve(ChasmLoader *l, void *handle) {
    /* Required symbols */
    l->module_init = (chasm_module_init_fn)dlsym(handle, "chasm_module_init");
    l->on_tick     = (chasm_on_tick_fn)    dlsym(handle, "chasm_on_tick");
    l->on_draw     = (chasm_on_draw_fn)    dlsym(handle, "chasm_on_draw");

    if (!l->module_init || !l->on_tick || !l->on_draw) {
        fprintf(stderr, "[loader] missing required symbol: %s\n", dlerror());
        return -1;
    }

    /* Optional symbols — fall back to no-op */
    void *sym;
    sym = dlsym(handle, "chasm_on_init");
    l->on_init = sym ? (chasm_on_init_fn)sym : chasm_loader_noop_ctx;

    sym = dlsym(handle, "chasm_on_unload");
    l->on_unload = sym ? (chasm_on_unload_fn)sym : chasm_loader_noop_ctx;

    sym = dlsym(handle, "chasm_reload_migrate");
    l->reload_migrate = sym ? (chasm_reload_migrate_fn)sym : chasm_loader_noop_ctx;

    l->handle = handle;
    return 0;
}

/* ---- Public API ------------------------------------------------------ */

/* Load the shared library at path. Returns 0 on success, -1 on failure. */
static int chasm_loader_open(ChasmLoader *l, const char *path) {
    memset(l, 0, sizeof(*l));
    int flags = RTLD_NOW | RTLD_LOCAL;
    void *handle = dlopen(path, flags);
    if (!handle) {
        fprintf(stderr, "[loader] dlopen failed: %s\n", dlerror());
        return -1;
    }
    if (chasm_loader_resolve(l, handle) != 0) {
        dlclose(handle);
        memset(l, 0, sizeof(*l));
        return -1;
    }
    fprintf(stderr, "[loader] opened %s (on_draw=%p)\n", path, (void*)l->on_draw);
    return 0;
}

/* Swap to a new shared library. Resets script+frame arenas, calls migrate.
 * On failure the old library remains loaded. Returns 0 on success, -1 on failure. */
static int chasm_loader_reload(ChasmLoader *l, ChasmCtx *ctx, const char *path) {
    int flags = RTLD_NOW | RTLD_LOCAL;
    void *new_handle = dlopen(path, flags);
    if (!new_handle) {
        fprintf(stderr, "[loader] reload dlopen failed: %s\n", dlerror());
        return -1;
    }

    /* Resolve symbols before closing old handle */
    ChasmLoader tmp = {0};
    if (chasm_loader_resolve(&tmp, new_handle) != 0) {
        dlclose(new_handle);
        return -1;
    }

    /* Close old handle now that new one is ready */
    if (l->handle) {
        dlclose(l->handle);
    }

    /* Commit the new loader state */
    *l = tmp;

    /* Reset transient arenas */
    chasm_clear_script(ctx);
    chasm_clear_frame(ctx);

    /* Re-initialize @attr globals from the new module, then call migrate */
    l->module_init(ctx);
    l->reload_migrate(ctx);

    fprintf(stderr, "[hot-reload] script reloaded (on_draw=%p)\n", (void*)l->on_draw);
    return 0;
}

/* Close the current handle (call on engine shutdown). */
static void chasm_loader_close(ChasmLoader *l) {
    if (l->handle) {
        dlclose(l->handle);
    }
    memset(l, 0, sizeof(*l));
}
