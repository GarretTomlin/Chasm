const std      = @import("std");
const builtin  = @import("builtin");
const ArenaTriple = @import("runtime").ArenaTriple;
const Lexer    = @import("lexer").Lexer;
const Parser   = @import("parser").Parser;
const AstPool  = @import("ast").AstPool;
const DiagList = @import("diag").DiagList;
const Sema     = @import("sema").Sema;
const Lowerer  = @import("lower").Lowerer;
const codegen      = @import("codegen");
const codegen_wasm = @import("codegen_wasm");
const reload   = @import("reload");
const ir_mod   = @import("ir");

const raylib_prelude: []const u8 =
    \\# ---- Window / system ---------------------------------------------------
    \\extern fn screen_w() -> int                                              = "rl_screen_width"
    \\extern fn screen_h() -> int                                              = "rl_screen_height"
    \\extern fn set_fps(fps: int) -> void                                      = "rl_set_target_fps"
    \\extern fn set_title(title: str) -> void                                  = "rl_set_window_title"
    \\extern fn fps() -> int                                                   = "rl_fps"
    \\extern fn dt() -> float                                                  = "rl_frame_time"
    \\extern fn time() -> float                                                = "rl_time"
    \\# ---- Draw --------------------------------------------------------------
    \\extern fn clear(color: int) -> void                                      = "rl_clear_background"
    \\extern fn draw_rect(x: float, y: float, w: float, h: float, color: int) -> void = "rl_draw_rectangle"
    \\extern fn draw_rect_lines(x: float, y: float, w: float, h: float, color: int) -> void = "rl_draw_rectangle_lines"
    \\extern fn draw_rect_rounded(x: float, y: float, w: float, h: float, r: float, seg: int, color: int) -> void = "rl_draw_rectangle_rounded"
    \\extern fn draw_circle(x: float, y: float, r: float, color: int) -> void = "rl_draw_circle"
    \\extern fn draw_circle_lines(x: float, y: float, r: float, color: int) -> void = "rl_draw_circle_lines"
    \\extern fn draw_line(x1: float, y1: float, x2: float, y2: float, color: int) -> void = "rl_draw_line"
    \\extern fn draw_line_ex(x1: float, y1: float, x2: float, y2: float, thick: float, color: int) -> void = "rl_draw_line_ex"
    \\extern fn draw_text(text: str, x: float, y: float, size: int, color: int) -> void = "rl_draw_text"
    \\extern fn measure_text(text: str, size: int) -> float                   = "rl_measure_text"
    \\extern fn draw_fps(x: float, y: float) -> void                          = "rl_draw_fps"
    \\# ---- Texture -----------------------------------------------------------
    \\extern fn load_texture(path: str) -> int                                 = "rl_load_texture"
    \\extern fn unload_texture(handle: int) -> void                            = "rl_unload_texture"
    \\extern fn draw_texture(handle: int, x: float, y: float, tint: int) -> void = "rl_draw_texture"
    \\extern fn draw_texture_ex(handle: int, x: float, y: float, rot: float, scale: float, tint: int) -> void = "rl_draw_texture_ex"
    \\extern fn draw_texture_rect(handle: int, sx: float, sy: float, sw: float, sh: float, dx: float, dy: float, tint: int) -> void = "rl_draw_texture_rec"
    \\extern fn texture_w(handle: int) -> int                                  = "rl_texture_width"
    \\extern fn texture_h(handle: int) -> int                                  = "rl_texture_height"
    \\# ---- Font --------------------------------------------------------------
    \\extern fn load_font(path: str) -> int                                    = "rl_load_font"
    \\extern fn draw_text_ex(font: int, text: str, x: float, y: float, size: float, spacing: float, color: int) -> void = "rl_draw_text_ex"
    \\# ---- Audio -------------------------------------------------------------
    \\extern fn init_audio() -> void                                           = "rl_init_audio"
    \\extern fn close_audio() -> void                                          = "rl_close_audio"
    \\extern fn load_sound(path: str) -> int                                   = "rl_load_sound"
    \\extern fn play_sound(handle: int) -> void                                = "rl_play_sound"
    \\extern fn stop_sound(handle: int) -> void                                = "rl_stop_sound"
    \\extern fn load_music(path: str) -> int                                   = "rl_load_music"
    \\extern fn play_music(handle: int) -> void                                = "rl_play_music"
    \\extern fn update_music(handle: int) -> void                              = "rl_update_music"
    \\extern fn stop_music(handle: int) -> void                                = "rl_stop_music"
    \\# ---- Keyboard ----------------------------------------------------------
    \\extern fn key_down(key: int) -> bool                                     = "rl_is_key_down"
    \\extern fn key_pressed(key: int) -> bool                                  = "rl_is_key_pressed"
    \\extern fn key_released(key: int) -> bool                                 = "rl_is_key_released"
    \\extern fn key_up(key: int) -> bool                                       = "rl_is_key_up"
    \\extern fn key_last() -> int                                              = "rl_get_key_pressed"
    \\# ---- Mouse -------------------------------------------------------------
    \\extern fn mouse_x() -> float                                             = "rl_mouse_x"
    \\extern fn mouse_y() -> float                                             = "rl_mouse_y"
    \\extern fn mouse_dx() -> float                                            = "rl_mouse_delta_x"
    \\extern fn mouse_dy() -> float                                            = "rl_mouse_delta_y"
    \\extern fn mouse_down(btn: int) -> bool                                   = "rl_is_mouse_down"
    \\extern fn mouse_pressed(btn: int) -> bool                                = "rl_is_mouse_pressed"
    \\extern fn mouse_released(btn: int) -> bool                               = "rl_is_mouse_released"
    \\extern fn mouse_wheel() -> float                                         = "rl_mouse_wheel"
    \\extern fn hide_cursor() -> void                                          = "rl_hide_cursor"
    \\extern fn show_cursor() -> void                                          = "rl_show_cursor"
    \\# ---- Collision ---------------------------------------------------------
    \\extern fn collide_rects(x1: float, y1: float, w1: float, h1: float, x2: float, y2: float, w2: float, h2: float) -> bool = "rl_check_collision_recs"
    \\extern fn collide_circles(x1: float, y1: float, r1: float, x2: float, y2: float, r2: float) -> bool = "rl_check_collision_circles"
    \\extern fn point_in_rect(px: float, py: float, rx: float, ry: float, rw: float, rh: float) -> bool = "rl_check_collision_point_rec"
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing = gpa.allocator();

    const args = try std.process.argsAlloc(backing);
    defer std.process.argsFree(backing, args);

    if (args.len < 2) {
        try usage();
        std.process.exit(1);
    }

    // ---- Sub-command dispatch ----------------------------------------------
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "version")) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.print("chasm 0.1.0\n", .{});
        return;
    }

    if (std.mem.eql(u8, args[1], "--watch") or std.mem.eql(u8, args[1], "watch")) {
        if (args.len < 3) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Usage: chasm --watch <file.chasm>\n", .{});
            std.process.exit(1);
        }
        try watchMode(args[2], backing);
        return;
    }

    if (std.mem.eql(u8, args[1], "run")) {
        if (args.len < 3) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Usage: chasm run <file.chasm> [--link libname ...] [--engine raylib]\n", .{});
            std.process.exit(1);
        }
        // Collect --link flags and --engine flag
        var link_libs = std.ArrayListUnmanaged([]const u8){};
        defer link_libs.deinit(backing);
        var file_path_run: []const u8 = "";
        var engine_raylib = false;
        var j: usize = 2;
        while (j < args.len) : (j += 1) {
            if (std.mem.eql(u8, args[j], "--link") and j + 1 < args.len) {
                j += 1;
                try link_libs.append(backing, args[j]);
            } else if (std.mem.eql(u8, args[j], "--engine") and j + 1 < args.len) {
                j += 1;
                if (std.mem.eql(u8, args[j], "raylib")) engine_raylib = true;
            } else {
                file_path_run = args[j];
            }
        }
        try runModeWithLinks(file_path_run, link_libs.items, engine_raylib, backing);
        return;
    }

    if (std.mem.eql(u8, args[1], "compile")) {
        if (args.len < 3) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Usage: chasm compile <file.chasm> [--link libname ...]\n", .{});
            std.process.exit(1);
        }
        var link_libs_compile = std.ArrayListUnmanaged([]const u8){};
        defer link_libs_compile.deinit(backing);
        var compile_path: []const u8 = args[2];
        var ci: usize = 3;
        while (ci < args.len) : (ci += 1) {
            if (std.mem.eql(u8, args[ci], "--link") and ci + 1 < args.len) {
                ci += 1;
                try link_libs_compile.append(backing, args[ci]);
            } else {
                compile_path = args[ci];
            }
        }
        var compile_arenas = ArenaTriple.init(backing);
        defer compile_arenas.deinit();
        const compile_frame = compile_arenas.allocator(.frame);
        const compile_module = try compileFile(compile_path, compile_frame) orelse std.process.exit(1);
        try writeOutput(compile_path, compile_module, compile_frame);
        if (link_libs_compile.items.len > 0) {
            const stdout = std.fs.File.stdout().deprecatedWriter();
            try stdout.print("  link flags:", .{});
            for (link_libs_compile.items) |lib| try stdout.print(" -l{s}", .{lib});
            try stdout.print("\n", .{});
        }
        return;
    }

    if (std.mem.eql(u8, args[1], "compare")) {
        if (args.len < 4) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            try stderr.print("Usage: chasm compare <old.chasm> <new.chasm>\n", .{});
            std.process.exit(1);
        }
        try compareMode(args[2], args[3], backing);
        return;
    }

    // ---- Default: single compile -------------------------------------------
    var arenas = ArenaTriple.init(backing);
    defer arenas.deinit();
    const frame_alloc = arenas.allocator(.frame);

    // Check for --target wasm flag
    var wasm_target = false;
    var path: []const u8 = args[1];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--target") and i + 1 < args.len) {
            if (std.mem.eql(u8, args[i + 1], "wasm")) {
                wasm_target = true;
                i += 1;
            }
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            path = args[i];
        }
    }

    const ir_module = try compileFile(path, frame_alloc) orelse std.process.exit(1);
    if (wasm_target) {
        try writeWasmOutput(path, ir_module, frame_alloc);
    } else {
        try writeOutput(path, ir_module, frame_alloc);
    }
    arenas.clearFrame();
}

// ---------------------------------------------------------------------------
// Compare two files and print the reload diff
// ---------------------------------------------------------------------------

fn compareMode(old_path: []const u8, new_path: []const u8, backing: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var old_arenas = ArenaTriple.init(backing);
    defer old_arenas.deinit();
    var new_arenas = ArenaTriple.init(backing);
    defer new_arenas.deinit();

    const old_module = try compileFile(old_path, old_arenas.allocator(.frame)) orelse {
        try stderr.print("compare: failed to compile {s}\n", .{old_path});
        std.process.exit(1);
    };
    const new_module = try compileFile(new_path, new_arenas.allocator(.frame)) orelse {
        try stderr.print("compare: failed to compile {s}\n", .{new_path});
        std.process.exit(1);
    };

    try stdout.print("Reload analysis: {s} → {s}\n\n", .{ old_path, new_path });
    var diff_arena = std.heap.ArenaAllocator.init(backing);
    defer diff_arena.deinit();
    const report = try reload.diff(old_module, new_module, diff_arena.allocator());
    try reload.renderReport(report, stdout);
}

// ---------------------------------------------------------------------------
// Watch mode — poll for file changes, recompile, show reload diff
// ---------------------------------------------------------------------------

fn watchMode(path: []const u8, backing: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    try stdout.print("[watch] {s}\n", .{path});

    // Snapshot of attrs from the last successful compile (null on first run).
    var prev_snap: ?reload.ModuleSnapshot = null;
    defer if (prev_snap) |*s| s.deinit(backing);

    var last_mtime: i128 = 0;

    while (true) {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            try stderr.print("[watch] stat error: {s}\n", .{@errorName(err)});
            std.Thread.sleep(1 * std.time.ns_per_s);
            continue;
        };

        if (stat.mtime != last_mtime) {
            last_mtime = stat.mtime;
            if (last_mtime != 0) {
                try stdout.print("\n[watch] {s} changed — recompiling...\n", .{path});
            }

            var arenas = ArenaTriple.init(backing);
            const frame_alloc = arenas.allocator(.frame);

            if (try compileFile(path, frame_alloc)) |new_module| {
                // Show reload diff if we have a previous version.
                if (prev_snap) |*old_snap| {
                    const old_ir = try old_snap.toIrModule(frame_alloc);
                    const report = try reload.diff(old_ir, new_module, frame_alloc);
                    try stdout.print("Reload analysis:\n", .{});
                    try reload.renderReport(report, stdout);
                }

                // Capture snapshot before clearing frame arena.
                const new_snap = try reload.ModuleSnapshot.capture(new_module, backing);
                if (prev_snap) |*s| s.deinit(backing);
                prev_snap = new_snap;

                try writeOutput(path, new_module, frame_alloc);
            }

            arenas.deinit();
        }

        std.Thread.sleep(300 * std.time.ns_per_ms);
    }
}

// ---------------------------------------------------------------------------
// Shared compilation pipeline
// ---------------------------------------------------------------------------

/// Compile `path` and return the `IrModule`, or print errors and return null.
/// All allocations use `frame_alloc` (caller is responsible for the arena).
/// Pass `verbose = false` to suppress the summary line (e.g. for `chasm run`).
fn compileFile(path: []const u8, frame_alloc: std.mem.Allocator) !?ir_mod.IrModule {
    return compileFileOpts(path, frame_alloc, true, null, null);
}

fn compileFileOpts(path: []const u8, frame_alloc: std.mem.Allocator, verbose: bool, imported_out: ?*std.ArrayListUnmanaged([]const u8), prelude: ?[]const u8) !?ir_mod.IrModule {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const file_src = std.fs.cwd().readFileAlloc(frame_alloc, path, 4 * 1024 * 1024) catch |err| {
        try stderr.print("{s}: read error: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    const src = if (prelude) |p|
        try std.mem.concat(frame_alloc, u8, &.{ p, "\n", file_src })
    else
        file_src;

    var pool  = AstPool.init(frame_alloc);
    var diags = DiagList.initWithSource(frame_alloc, src);

    var lexer = Lexer.init(src);
    const tokens = lexer.tokenize(frame_alloc) catch |err| {
        try stderr.print("{s}: lex error: {s}\n", .{ path, @errorName(err) });
        return null;
    };

    var parser = Parser.init(tokens, &pool, &diags, frame_alloc);
    const top_level = parser.parseFile() catch |err| {
        try diags.render(path, stderr);
        try stderr.print("{s}: parse error: {s}\n", .{ path, @errorName(err) });
        return null;
    };

    if (diags.hasErrors()) {
        try diags.render(path, stderr);
        return null;
    }

    var sema = Sema.initWithFile(&pool, &diags, frame_alloc, path);
    try sema.analyze(top_level);

    // Collect imported file paths if the caller wants them.
    if (imported_out) |out| {
        for (sema.imported_files.items) |imp| {
            try out.append(frame_alloc, imp);
        }
    }

    if (diags.hasErrors()) {
        try diags.render(path, stderr);
        return null;
    }

    var lowerer = Lowerer.init(&pool, &sema, frame_alloc);
    const ir_module = try lowerer.lower(top_level);

    if (verbose) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const s = sema.stats;
        try stdout.print("{s}: {d} decls, {d} symbols — frame:{d} script:{d} persistent:{d}\n",
            .{ path, top_level.len, s.symbols_resolved, s.frame_vars, s.script_vars, s.persistent_vars });
    }

    return ir_module;
}

/// Write WAT output for a compiled module (WASM target).
fn writeWasmOutput(path: []const u8, ir_module: ir_mod.IrModule, frame_alloc: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const out_path = blk: {
        if (std.mem.endsWith(u8, path, ".chasm")) {
            const base = path[0 .. path.len - ".chasm".len];
            break :blk try std.fmt.allocPrint(frame_alloc, "{s}.wat", .{base});
        }
        break :blk try std.fmt.allocPrint(frame_alloc, "{s}.wat", .{path});
    };

    const wat_file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        try stderr.print("{s}: write error: {s}\n", .{ out_path, @errorName(err) });
        return;
    };
    defer wat_file.close();
    try codegen_wasm.emitWat(ir_module, wat_file.deprecatedWriter());

    try stdout.print("  output → {s}\n", .{out_path});
}

/// Write C output and runtime header for a compiled module.
fn writeOutput(path: []const u8, ir_module: ir_mod.IrModule, frame_alloc: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const out_path = blk: {
        if (std.mem.endsWith(u8, path, ".chasm")) {
            const base = path[0 .. path.len - ".chasm".len];
            break :blk try std.fmt.allocPrint(frame_alloc, "{s}.c", .{base});
        }
        break :blk try std.fmt.allocPrint(frame_alloc, "{s}.c", .{path});
    };

    const c_file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        try stderr.print("{s}: write error: {s}\n", .{ out_path, @errorName(err) });
        return;
    };
    defer c_file.close();
    try codegen.emitModule(ir_module, c_file.deprecatedWriter());

    // Write runtime header alongside source if not already present.
    const dir     = std.fs.path.dirname(out_path) orelse ".";
    const rt_path = try std.fmt.allocPrint(frame_alloc, "{s}/chasm_rt.h", .{dir});
    const rt_file = std.fs.cwd().createFile(rt_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return err,
    };
    if (rt_file) |f| {
        defer f.close();
        try codegen.emitRuntimeHeader(f.deprecatedWriter());
    }

    try stdout.print("  output → {s}\n", .{out_path});
}

// ---------------------------------------------------------------------------
// Run mode — compile to C, generate harness, invoke cc, execute
// ---------------------------------------------------------------------------

fn runModeWithLinks(path: []const u8, link_libs: []const []const u8, engine_raylib: bool, backing: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var arenas = ArenaTriple.init(backing);
    defer arenas.deinit();
    const frame_alloc = arenas.allocator(.frame);

    const prelude: ?[]const u8 = if (engine_raylib) raylib_prelude else null;
    var imported_files = std.ArrayListUnmanaged([]const u8){};
    const ir_module = try compileFileOpts(path, frame_alloc, false, &imported_files, prelude) orelse std.process.exit(1);

    // Derive output paths in a temp directory.
    const tmp_dir = try std.fmt.allocPrint(frame_alloc, "/tmp/chasm_run_{d}", .{std.time.milliTimestamp()});
    try std.fs.cwd().makePath(tmp_dir);

    // Write generated C.
    const c_path = try std.fmt.allocPrint(frame_alloc, "{s}/script.c", .{tmp_dir});
    const c_file = try std.fs.cwd().createFile(c_path, .{});
    if (engine_raylib) {
        try codegen.emitModuleRaylib(ir_module, c_file.deprecatedWriter());
    } else {
        try codegen.emitModule(ir_module, c_file.deprecatedWriter());
    }
    c_file.close();

    // Write runtime header.
    const rt_path = try std.fmt.allocPrint(frame_alloc, "{s}/chasm_rt.h", .{tmp_dir});
    const rt_file = try std.fs.cwd().createFile(rt_path, .{});
    try codegen.emitRuntimeHeader(rt_file.deprecatedWriter());
    rt_file.close();

    // Write chasm_rl.h when using the raylib engine.
    if (engine_raylib) {
        const rl_h_path = try std.fmt.allocPrint(frame_alloc, "{s}/chasm_rl.h", .{tmp_dir});
        const rl_h_file = try std.fs.cwd().createFile(rl_h_path, .{});
        try codegen.emitRaylibHeader(rl_h_file.deprecatedWriter());
        rl_h_file.close();
    }

    // Write harness.
    const harness_path = try std.fmt.allocPrint(frame_alloc, "{s}/harness.c", .{tmp_dir});
    const harness_file = try std.fs.cwd().createFile(harness_path, .{});
    const hw = harness_file.deprecatedWriter();

    if (engine_raylib) {
        // ---- Raylib game-loop harness ------------------------------------
        // Detect which hooks the script provides.
        var has_on_init   = false;
        var has_on_tick   = false;
        var has_on_draw   = false;
        var has_on_unload = false;
        for (ir_module.functions) |func| {
            if (std.mem.eql(u8, func.name, "on_init"))   has_on_init   = true;
            if (std.mem.eql(u8, func.name, "on_tick"))   has_on_tick   = true;
            if (std.mem.eql(u8, func.name, "on_draw"))   has_on_draw   = true;
            if (std.mem.eql(u8, func.name, "on_unload")) has_on_unload = true;
        }
        try hw.print("#include \"chasm_rl.h\"\n\n", .{});
        try hw.print("void chasm_module_init(ChasmCtx *ctx);\n", .{});
        if (has_on_tick)   try hw.print("void chasm_on_tick(ChasmCtx *ctx, double dt);\n", .{});
        if (has_on_draw)   try hw.print("void chasm_on_draw(ChasmCtx *ctx);\n", .{});
        if (has_on_init) {
            try hw.print("void chasm_on_init(ChasmCtx *ctx);\n", .{});
        } else {
            try hw.print("static void chasm_on_init(ChasmCtx *ctx) {{ (void)ctx; }}\n", .{});
        }
        if (has_on_unload) {
            try hw.print("void chasm_on_unload(ChasmCtx *ctx);\n", .{});
        } else {
            try hw.print("static void chasm_on_unload(ChasmCtx *ctx) {{ (void)ctx; }}\n", .{});
        }
        try hw.print(
            \\
            \\int main(void) {{
            \\    static uint8_t frame_mem  [ 1*1024*1024];
            \\    static uint8_t script_mem [ 4*1024*1024];
            \\    static uint8_t persist_mem[16*1024*1024];
            \\    ChasmCtx ctx = {{
            \\        .frame      = {{frame_mem,   0, sizeof(frame_mem)}},
            \\        .script     = {{script_mem,  0, sizeof(script_mem)}},
            \\        .persistent = {{persist_mem, 0, sizeof(persist_mem)}},
            \\    }};
            \\    chasm_module_init(&ctx);
            \\    InitWindow(800, 600, "Chasm Game");
            \\    SetTargetFPS(60);
            \\    chasm_on_init(&ctx);
            \\    while (!WindowShouldClose()) {{
            \\        double dt = (double)GetFrameTime();
            \\
            , .{});
        if (has_on_tick) try hw.print("        chasm_on_tick(&ctx, dt);\n", .{});
        try hw.print(
            \\        BeginDrawing();
            \\        ClearBackground((Color){{0,0,0,255}});
            \\
            , .{});
        if (has_on_draw) try hw.print("        chasm_on_draw(&ctx);\n", .{});
        try hw.print(
            \\        EndDrawing();
            \\        chasm_clear_frame(&ctx);
            \\    }}
            \\    chasm_on_unload(&ctx);
            \\    CloseWindow();
            \\    return 0;
            \\}}
            \\
            , .{});
    } else {
        // ---- Standard harness: call every public zero-arg function -------
        try hw.print("#include \"chasm_rt.h\"\n#include <stdio.h>\n#include <stdlib.h>\n\n", .{});
        var has_callable = false;
        for (ir_module.functions) |func| {
            if (!func.is_public or func.params.len > 0) continue;
            try hw.print("void chasm_{s}(ChasmCtx *ctx);\n", .{func.name});
            has_callable = true;
        }
        try hw.print("void chasm_module_init(ChasmCtx *ctx);\n\n", .{});
        try hw.print(
            \\int main(void) {{
            \\    uint8_t frame_mem[64*1024], script_mem[64*1024], persist_mem[256*1024];
            \\    ChasmCtx ctx = {{
            \\        .frame      = {{frame_mem,   0, sizeof(frame_mem)}},
            \\        .script     = {{script_mem,  0, sizeof(script_mem)}},
            \\        .persistent = {{persist_mem, 0, sizeof(persist_mem)}},
            \\    }};
            \\    chasm_module_init(&ctx);
            \\
            , .{});
        for (ir_module.functions) |func| {
            if (!func.is_public or func.params.len > 0) continue;
            try hw.print("    chasm_{s}(&ctx);\n", .{func.name});
            try hw.print("    chasm_clear_frame(&ctx);\n", .{});
        }
        if (!has_callable) {
            try hw.print("    printf(\"(no public zero-argument functions to call)\\n\");\n", .{});
        }
        try hw.print(
            \\    return 0;
            \\}}
            \\
            , .{});
    }
    harness_file.close();

    // Compile imported modules to C files.
    var imported_c_paths = std.ArrayListUnmanaged([]const u8){};
    defer imported_c_paths.deinit(backing);
    for (imported_files.items) |imp_path| {
        const imp_module = try compileFileOpts(imp_path, frame_alloc, false, null, null) orelse continue;
        const imp_c_path = try std.fmt.allocPrint(frame_alloc, "{s}/imported_{d}.c", .{ tmp_dir, imported_c_paths.items.len });
        const imp_c_file = try std.fs.cwd().createFile(imp_c_path, .{});
        try codegen.emitModuleImported(imp_module, imp_c_file.deprecatedWriter());
        imp_c_file.close();
        try imported_c_paths.append(backing, imp_c_path);
    }

    // Compile.
    const bin_path = try std.fmt.allocPrint(frame_alloc, "{s}/out", .{tmp_dir});
    var cc_argv_list = std.ArrayListUnmanaged([]const u8){};
    defer cc_argv_list.deinit(backing);
    // Imported C files go first so their declarations are visible to the main script.
    try cc_argv_list.appendSlice(backing, &.{ "cc", "-o", bin_path });
    for (imported_c_paths.items) |icp| {
        try cc_argv_list.append(backing, icp);
    }
    try cc_argv_list.appendSlice(backing, &.{ c_path, harness_path, "-I", tmp_dir });
    for (link_libs) |lib| {
        const flag = try std.fmt.allocPrint(frame_alloc, "-l{s}", .{lib});
        try cc_argv_list.append(backing, flag);
    }
    if (engine_raylib) {
        // Find raylib relative to cwd (engine/raylib-5.5_macos) or exe dir.
        const cwd_raylib = "engine/raylib-5.5_macos";
        const raylib_dir: []const u8 = blk: {
            std.fs.cwd().access(cwd_raylib, .{}) catch {
                // Fall back to path relative to the executable.
                const exe_dir = std.fs.selfExeDirPathAlloc(backing) catch break :blk cwd_raylib;
                defer backing.free(exe_dir);
                const alt = try std.fmt.allocPrint(frame_alloc, "{s}/../../engine/raylib-5.5_macos", .{exe_dir});
                break :blk alt;
            };
            break :blk cwd_raylib;
        };
        const inc = try std.fmt.allocPrint(frame_alloc, "{s}/include", .{raylib_dir});
        const lib = try std.fmt.allocPrint(frame_alloc, "{s}/lib", .{raylib_dir});
        const static_lib = try std.fmt.allocPrint(frame_alloc, "{s}/libraylib.a", .{lib});
        try cc_argv_list.appendSlice(backing, &.{ "-I", inc, static_lib });
        // macOS system frameworks required by raylib.
        if (builtin.os.tag == .macos) {
            try cc_argv_list.appendSlice(backing, &.{
                "-framework", "OpenGL",
                "-framework", "Cocoa",
                "-framework", "IOKit",
                "-framework", "CoreVideo",
                "-framework", "CoreAudio",
                "-framework", "AudioToolbox",
            });
        } else if (builtin.os.tag == .linux) {
            try cc_argv_list.appendSlice(backing, &.{ "-lGL", "-lm", "-lpthread", "-ldl", "-lrt", "-lX11" });
        }
    }
    var cc_proc = std.process.Child.init(cc_argv_list.items, backing);
    cc_proc.stderr_behavior = .Inherit;
    const cc_term = try cc_proc.spawnAndWait();
    if (cc_term != .Exited or cc_term.Exited != 0) {
        try stderr.print("chasm run: cc failed\n", .{});
        std.process.exit(1);
    }

    try stdout.print("  running {s}...\n\n", .{path});

    // Execute.
    const run_argv = [_][]const u8{bin_path};
    var run_proc = std.process.Child.init(&run_argv, backing);
    run_proc.stdout_behavior = .Inherit;
    run_proc.stderr_behavior = .Inherit;
    const run_term = try run_proc.spawnAndWait();
    if (run_term == .Exited) std.process.exit(run_term.Exited);
}

fn usage() !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.print(
        \\Usage:
        \\  chasm run <file.chasm> [--link lib]  — compile and run immediately
        \\  chasm compile <file.chasm> [--link lib] — compile to C (with link hint)
        \\  chasm <file.chasm>                   — compile to C
        \\  chasm compare <old.chasm> <new>      — show hot-reload diff
        \\  chasm --watch <file.chasm>           — watch + recompile on change
        \\  chasm --version                      — print version
        \\
        , .{});
}
