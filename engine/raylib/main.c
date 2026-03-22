/* engine/main.c — Chasm + Raylib hot-reload host.
 *
 * The engine binary is compiled once. The script is loaded as a shared
 * library (.dylib / .so) at startup and swapped in-place on hot-reload
 * without closing the window.
 *
 * Build (engine binary only — no script code):
 *   macOS:
 *     cc -o /tmp/chasm_engine engine/main.c \
 *       -I engine/ \
 *       -I engine/raylib-5.5_macos/include \
 *       engine/raylib-5.5_macos/lib/libraylib.a \
 *       -framework OpenGL -framework Cocoa -framework IOKit \
 *       -framework CoreVideo -framework CoreAudio -framework AudioToolbox
 *
 * Or use: chasm watch --engine raylib game.chasm
 *
 * The compiled Chasm script MUST export (via the shared library):
 *   chasm_module_init(ctx)   — initialise @attr globals
 *   chasm_on_tick(ctx, dt)   — game logic, input, physics
 *   chasm_on_draw(ctx)       — all rendering
 *
 * Optional exports (no-op stub used if absent):
 *   chasm_on_init(ctx)       — called once after window opens
 *   chasm_on_unload(ctx)     — called before window closes
 *   chasm_reload_migrate(ctx)— called after each hot-reload swap
 */
#include "chasm_rl.h"
#include "loader.h"

int main(int argc, char **argv) {
    /* argv[1] = path to initial script dylib (written by CLI before launch) */
    const char *script_path = argc > 1 ? argv[1] : "/tmp/chasm_script" CHASM_SCRIPT_EXT;
    /* ---- Arena layout ------------------------------------------ *
     *  frame      (1 MB)  — cleared every tick                      *
     *  script     (4 MB)  — reset on hot-reload                     *
     *  persistent (16 MB) — never cleared; survives reloads         *
     * ------------------------------------------------------------ */
    static uint8_t frame_mem  [ 1 * 1024 * 1024];
    static uint8_t script_mem [ 4 * 1024 * 1024];
    static uint8_t persist_mem[16 * 1024 * 1024];

    ChasmCtx ctx = {
        .frame      = { frame_mem,   0, sizeof(frame_mem)   },
        .script     = { script_mem,  0, sizeof(script_mem)  },
        .persistent = { persist_mem, 0, sizeof(persist_mem) },
    };

    /* ---- Load script shared library ----------------------------- */
    ChasmLoader loader = {0};
    if (chasm_loader_open(&loader, script_path) != 0) {
        return 1;
    }

    /* Run @attr initializers (script-level constructors) */
    loader.module_init(&ctx);

    /* Open window */
    InitWindow(800, 600, "Chasm Game");
    SetTargetFPS(60);

    /* Optional: load assets, start music, etc. */
    loader.on_init(&ctx);

    /* ---- Main loop --------------------------------------------- */
    while (!WindowShouldClose()) {
        double dt = (double)GetFrameTime();

        /* Tick: input + game logic */
        loader.on_tick(&ctx, dt);

        /* Draw: everything between Begin/EndDrawing */
        BeginDrawing();
        ClearBackground(BLACK);
        loader.on_draw(&ctx);
        EndDrawing();

        /* Reclaim frame-lifetime allocations */
        chasm_clear_frame(&ctx);

        /* ---- Hot-reload check ----------------------------------- *
         * Poll for sentinel file once per frame (cheap stat call).  *
         * Sentinel contains the path to the new dylib.              *
         * Unlink before swap so exactly one reload per write.       *
         * --------------------------------------------------------- */
        if (access(CHASM_RELOAD_SENTINEL, F_OK) == 0) {
            char new_path[4096];
            if (chasm_read_sentinel(new_path, sizeof(new_path)) == 0) {
                unlink(CHASM_RELOAD_SENTINEL);
                chasm_loader_reload(&loader, &ctx, new_path);
            } else {
                unlink(CHASM_RELOAD_SENTINEL);
            }
        }
    }

    /* Optional: flush saves, unload assets */
    loader.on_unload(&ctx);
    chasm_loader_close(&loader);
    CloseWindow();
    return 0;
}
