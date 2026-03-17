/// WebAssembly Text Format (.wat) emitter for Chasm.
const std    = @import("std");
const ir_mod = @import("ir");
const IrModule   = ir_mod.IrModule;
const IrFunction = ir_mod.IrFunction;
const Instr      = ir_mod.Instr;
const Temp       = ir_mod.Temp;

pub fn emitWat(module: IrModule, writer: anytype) !void {
    try writer.print("(module\n", .{});

    // globals (module attrs)
    for (module.attrs) |a| {
        const wt = watType(a.type_id);
        try writer.print("  (global $g_{s} (mut {s}) ({s}.const 0))\n", .{a.name, wt, wt});
    }

    // functions
    for (module.functions) |f| {
        try emitWatFunction(f, writer);
    }

    try writer.print(")\n", .{});
}

fn emitWatFunction(f: IrFunction, writer: anytype) !void {
    const export_str: []const u8 = if (f.is_public)
        try std.fmt.allocPrint(std.heap.page_allocator, " (export \"{s}\")", .{f.name})
    else
        "";

    try writer.print("  (func ${s}{s}", .{f.name, export_str});

    // params
    for (f.params) |p| {
        try writer.print(" (param $t{d} {s})", .{p.temp_id, watType(p.type_id)});
    }

    // result type (infer from ret instructions)
    const ret_ty = inferRetType(f);
    if (ret_ty != 6) { // not void
        try writer.print(" (result {s})", .{watType(ret_ty)});
    }
    try writer.print("\n", .{});

    // locals
    for (f.temps) |t| {
        var is_param = false;
        for (f.params) |p| { if (p.temp_id == t.id) { is_param = true; break; } }
        if (!is_param) {
            try writer.print("    (local $t{d} {s})\n", .{t.id, watType(t.type_id)});
        }
    }

    // instructions
    for (f.instrs) |instr| {
        try emitWatInstr(instr, f.temps, writer);
    }

    try writer.print("  )\n", .{});
}

fn emitWatInstr(instr: Instr, temps: []const Temp, writer: anytype) !void {
    _ = temps;
    switch (instr) {
        .const_int   => |i| try writer.print("    (local.set $t{d} (i64.const {d}))\n", .{i.dest, i.value}),
        .const_float => |i| try writer.print("    (local.set $t{d} (f64.const {d}))\n", .{i.dest, i.value}),
        .const_bool  => |i| try writer.print("    (local.set $t{d} (i32.const {d}))\n", .{i.dest, if (i.value) @as(i32, 1) else @as(i32, 0)}),
        .copy        => |i| try writer.print("    (local.set $t{d} (local.get $t{d}))\n", .{i.dest, i.src}),
        .promote     => |i| try writer.print("    (local.set $t{d} (local.get $t{d}))\n", .{i.dest, i.src}),
        .load_attr   => |i| try writer.print("    (local.set $t{d} (global.get $g_{s}))\n", .{i.dest, i.name}),
        .store_attr  => |i| try writer.print("    (global.set $g_{s} (local.get $t{d}))\n", .{i.name, i.src}),
        .ret         => |t| try writer.print("    (return (local.get $t{d}))\n", .{t}),
        .ret_void    =>     try writer.print("    (return)\n", .{}),
        .label       => |id| try writer.print("    ;; L{d}:\n", .{id}),
        .binary      => |i| {
            const op = watBinaryOp(i.op);
            try writer.print("    (local.set $t{d} ({s} (local.get $t{d}) (local.get $t{d})))\n",
                .{i.dest, op, i.left, i.right});
        },
        .branch => |i| {
            try writer.print("    (if (local.get $t{d}) (then) (else))\n", .{i.cond});
            _ = i.then_lbl; _ = i.else_lbl;
        },
        .jump => |lbl| try writer.print("    ;; jump L{d}\n", .{lbl}),
        else => try writer.print("    ;; (unsupported instr)\n", .{}),
    }
}

fn watType(type_id: u32) []const u8 {
    return switch (type_id) {
        0, 1 => "i64",   // T_UNKNOWN, T_INT
        2    => "f64",   // T_FLOAT
        3    => "i32",   // T_BOOL
        4, 5 => "i32",   // T_STRING, T_ATOM (pointer as i32)
        else => "i64",
    };
}

fn watBinaryOp(op: ir_mod.BinaryOp) []const u8 {
    return switch (op) {
        .add => "i64.add",
        .sub => "i64.sub",
        .mul => "i64.mul",
        .div => "i64.div_s",
        .lt  => "i64.lt_s",
        .gt  => "i64.gt_s",
        .lte => "i64.le_s",
        .gte => "i64.ge_s",
        .eq  => "i64.eq",
        .neq => "i64.ne",
        else => "i64.add",
    };
}

fn inferRetType(f: IrFunction) u32 {
    for (f.instrs) |instr| {
        switch (instr) {
            .ret => |t| {
                if (t < f.temps.len) return f.temps[t].type_id;
                return 1;
            },
            else => {},
        }
    }
    return 6; // void
}
