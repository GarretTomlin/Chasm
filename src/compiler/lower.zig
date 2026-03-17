/// AST → IR lowering pass.
///
/// Walks the sema-annotated AST and emits three-address IR instructions.
/// All lifetime information is taken from the solved InferenceTable via
/// `Sema.lifetimeOf`.  Name resolution re-uses the Chasm scoping rules (inner
/// blocks see outer locals) via a lightweight `LowerScope` stack.
///
/// Key conventions:
///   - Every expression is lowered to a fresh `TempId`.
///   - Variable bindings register name → TempId in the current LowerScope.
///   - Ident *reads* return the existing TempId without emitting a copy.
///   - `var_decl` with an explicit lifetime different from the init expression's
///     solved lifetime emits a `promote` rather than a plain `copy`.
///   - Attr store targets (`@score = val`) emit `store_attr`, not `copy`.

const std     = @import("std");
const ast_mod = @import("ast");
const ir_mod  = @import("ir");
const sema_mod = @import("sema");

const NodeIndex = ast_mod.NodeIndex;
const AstPool   = ast_mod.AstPool;
const Lifetime  = @import("runtime").Lifetime;
const Sema      = sema_mod.Sema;
const IrModule  = ir_mod.IrModule;
const IrFunction = ir_mod.IrFunction;
const IrAttr    = ir_mod.IrAttr;
const IrParam   = ir_mod.IrParam;
const Instr     = ir_mod.Instr;
const Temp      = ir_mod.Temp;
const TempId    = ir_mod.TempId;
const LabelId   = ir_mod.LabelId;
const invalid_temp = ir_mod.invalid_temp;

// ---------------------------------------------------------------------------
// LowerScope: name → TempId resolution
// ---------------------------------------------------------------------------

const LowerScope = struct {
    vars:   std.StringHashMapUnmanaged(TempId) = .{},
    parent: ?*LowerScope = null,

    fn deinit(self: *LowerScope, alloc: std.mem.Allocator) void {
        self.vars.deinit(alloc);
    }

    fn define(self: *LowerScope, alloc: std.mem.Allocator, name: []const u8, temp: TempId) !void {
        try self.vars.put(alloc, name, temp);
    }

    fn lookup(self: *const LowerScope, name: []const u8) ?TempId {
        if (self.vars.get(name)) |t| return t;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    /// Overwrite an existing binding (for implicit re-assignment).
    fn update(self: *LowerScope, name: []const u8, temp: TempId) bool {
        if (self.vars.getPtr(name)) |ptr| { ptr.* = temp; return true; }
        if (self.parent) |p| return p.update(name, temp);
        return false;
    }
};

// ---------------------------------------------------------------------------
// Lowerer
// ---------------------------------------------------------------------------

pub const Lowerer = struct {
    pool:      *const AstPool,
    sema:      *const Sema,
    allocator: std.mem.Allocator,
    /// Imported function forward declarations to include in the IrModule.
    imported_fwd_decls: std.ArrayListUnmanaged(ir_mod.IrImportedFn),

    // ---- per-function mutable state ----------------------------------------
    instrs:     std.ArrayListUnmanaged(Instr),
    temps:      std.ArrayListUnmanaged(Temp),
    next_temp:  TempId,
    next_label: LabelId,
    scope_stack: std.ArrayListUnmanaged(*LowerScope),

    pub fn init(pool: *const AstPool, sema: *const Sema, allocator: std.mem.Allocator) Lowerer {
        return .{
            .pool        = pool,
            .sema        = sema,
            .allocator   = allocator,
            .instrs      = .{},
            .temps       = .{},
            .next_temp   = 0,
            .next_label  = 0,
            .scope_stack = .{},
            .imported_fwd_decls = .{},
        };
    }

    pub fn deinit(self: *Lowerer) void {
        self.instrs.deinit(self.allocator);
        self.temps.deinit(self.allocator);
        for (self.scope_stack.items) |s| {
            s.deinit(self.allocator);
            self.allocator.destroy(s);
        }
        self.scope_stack.deinit(self.allocator);
        self.imported_fwd_decls.deinit(self.allocator);
    }

    // ---- Main entry --------------------------------------------------------

    pub fn lower(self: *Lowerer, top_level: []const NodeIndex) !IrModule {
        var functions     = std.ArrayListUnmanaged(IrFunction){};
        var attrs         = std.ArrayListUnmanaged(IrAttr){};
        var enum_variants = std.ArrayListUnmanaged(ir_mod.IrEnumVariant){};
        var extern_fns    = std.ArrayListUnmanaged(ir_mod.IrExternFn){};

        // Collect attr init instructions into a separate stream.
        var init_instrs = std.ArrayListUnmanaged(Instr){};
        var init_temps  = std.ArrayListUnmanaged(Temp){};

        for (top_level) |idx| {
            switch (self.pool.get(idx).*) {
                .fn_decl    => try functions.append(self.allocator, try self.lowerFnDecl(idx)),
                .attr_decl  => try attrs.append(self.allocator,
                    try self.lowerAttrDecl(idx, &init_instrs, &init_temps)),
                .struct_decl => {}, // struct layout handled by codegen, no IR needed yet
                .enum_decl  => |e| {
                    for (e.variants, 0..) |v, i| {
                        try enum_variants.append(self.allocator, .{
                            .enum_name    = e.name,
                            .variant_name = v,
                            .index        = @intCast(i),
                        });
                    }
                },
                .extern_decl => |ex| {
                    try extern_fns.append(self.allocator, .{
                        .name   = ex.name,
                        .c_name = ex.c_name,
                    });
                },
                .import_decl => {}, // module resolution handled in sema
                else        => {},
            }
        }

        // Build imported_fwd_decls from sema's imported_fn_sigs.
        var imported_fwd = std.ArrayListUnmanaged(ir_mod.IrImportedFn){};
        for (self.sema.imported_fn_sigs.items) |sig| {
            var param_types = try self.allocator.alloc([]const u8, sig.param_type_ids.len);
            for (sig.param_type_ids, 0..) |tid, pi| {
                param_types[pi] = cTypeOfId(tid);
            }
            try imported_fwd.append(self.allocator, .{
                .name         = sig.name,
                .ret_c_type   = cTypeOfId(sig.ret_type_id),
                .param_c_types = param_types,
            });
        }

        return IrModule{
            .functions          = try functions.toOwnedSlice(self.allocator),
            .attrs              = try attrs.toOwnedSlice(self.allocator),
            .attr_init_instrs   = try init_instrs.toOwnedSlice(self.allocator),
            .attr_init_temps    = try init_temps.toOwnedSlice(self.allocator),
            .enum_variants      = try enum_variants.toOwnedSlice(self.allocator),
            .extern_fns         = try extern_fns.toOwnedSlice(self.allocator),
            .imported_fwd_decls = try imported_fwd.toOwnedSlice(self.allocator),
        };
    }

    fn cTypeOfId(type_id: u32) []const u8 {
        return switch (type_id) {
            0 => "int64_t",
            1 => "int64_t",
            2 => "double",
            3 => "bool",
            4, 5 => "const char*",
            6 => "void",
            7 => "ChasmArray",
            else => "int64_t",
        };
    }

    // ---- Function lowering -------------------------------------------------

    fn lowerFnDecl(self: *Lowerer, idx: NodeIndex) !IrFunction {
        const f = self.pool.get(idx).fn_decl;

        // Reset per-function state.
        self.instrs.clearRetainingCapacity();
        self.temps.clearRetainingCapacity();
        self.next_temp  = 0;
        self.next_label = 0;
        // Clear any leftover scope stack.
        for (self.scope_stack.items) |s| { s.deinit(self.allocator); self.allocator.destroy(s); }
        self.scope_stack.clearRetainingCapacity();

        // Push function scope and define params.
        try self.pushScope();
        var params = std.ArrayListUnmanaged(IrParam){};
        for (f.params) |p| {
            const lt = resolveLifetime(p.lifetime, .frame);
            const type_id: u32 = if (p.ty) |ty_idx| blk: {
                switch (self.pool.get(ty_idx).*) {
                    .type_ref => |tr| break :blk sema_mod.typeIdFromName(tr.name),
                    else      => break :blk @as(u32, 0),
                }
            } else @as(u32, 0);
            const t  = try self.freshTemp(lt, type_id);
            try (self.currentScope()).define(self.allocator, p.name, t);
            try params.append(self.allocator, .{
                .name    = p.name,
                .temp_id = t,
                .lifetime = lt,
                .type_id  = type_id,
            });
        }

        // Lower body block.
        try self.lowerBlock(f.body);
        // Implicit ret_void if not already terminated.
        if (!self.endsWithTerminator()) try self.emit(.ret_void);

        self.popScope();

        return IrFunction{
            .name      = f.name,
            .is_public = f.is_public,
            .params    = try params.toOwnedSlice(self.allocator),
            .temps     = try self.temps.toOwnedSlice(self.allocator),
            .instrs    = try self.instrs.toOwnedSlice(self.allocator),
        };
    }

    fn lowerAttrDecl(
        self: *Lowerer,
        idx: NodeIndex,
        init_instrs: *std.ArrayListUnmanaged(Instr),
        init_temps:  *std.ArrayListUnmanaged(Temp),
    ) !IrAttr {
        const a  = self.pool.get(idx).attr_decl;
        const lt = resolveLifetime(a.lifetime, .script);

        // Lower the init expression into the shared init stream.
        self.instrs.clearRetainingCapacity();
        self.temps.clearRetainingCapacity();
        self.next_temp = @intCast(init_temps.items.len); // continue global numbering
        for (self.scope_stack.items) |s| { s.deinit(self.allocator); self.allocator.destroy(s); }
        self.scope_stack.clearRetainingCapacity();

        const init_temp = try self.lowerExpr(a.init);

        // Splice into the shared streams.
        for (self.instrs.items) |instr| try init_instrs.append(self.allocator, instr);
        for (self.temps.items)  |t|    try init_temps.append(self.allocator,  t);

        return IrAttr{
            .name      = a.name,
            .lifetime  = lt,
            .type_id   = self.sema.nodeType(a.init),
            .init_temp = init_temp,
        };
    }

    // ---- Block & statement -------------------------------------------------

    fn lowerBlock(self: *Lowerer, idx: NodeIndex) anyerror!void {
        const block = self.pool.get(idx).block;
        try self.pushScope();
        defer self.popScope();
        for (block.stmts) |stmt| try self.lowerStmt(stmt);
    }

    fn lowerStmt(self: *Lowerer, idx: NodeIndex) anyerror!void {
        switch (self.pool.get(idx).*) {
            .var_decl   => try self.lowerVarDecl(idx),
            .assign     => try self.lowerAssign(idx),
            .if_stmt    => try self.lowerIf(idx),
            .while_stmt => try self.lowerWhile(idx),
            .for_in     => try self.lowerForIn(idx),
            .return_stmt => |rs| {
                if (rs.value != ast_mod.invalid_node) {
                    const t = try self.lowerExpr(rs.value);
                    try self.emit(.{ .ret = t });
                } else {
                    try self.emit(.ret_void);
                }
            },
            .expr_stmt  => |es| _ = try self.lowerExpr(es.expr),
            .block      => try self.lowerBlock(idx),
            else        => {},
        }
    }

    fn lowerVarDecl(self: *Lowerer, idx: NodeIndex) anyerror!void {
        const vd     = self.pool.get(idx).var_decl;
        const decl_lt = resolveLifetime(vd.lifetime, .frame);
        const init_t  = try self.lowerExpr(vd.init);
        const init_lt = self.temps.items[init_t].lifetime;

        if (init_lt == decl_lt) {
            // Alias: the var is the init temp.
            try (self.currentScope()).define(self.allocator, vd.name, init_t);
        } else if (@intFromEnum(init_lt) < @intFromEnum(decl_lt)) {
            // init has shorter lifetime than declared → promote.
            const dest_t = try self.freshTemp(decl_lt, self.sema.nodeType(vd.init));
            try self.emit(.{ .promote = .{ .dest = dest_t, .src = init_t, .from = init_lt, .to = decl_lt } });
            try (self.currentScope()).define(self.allocator, vd.name, dest_t);
        } else {
            // init already has a longer (or equal) lifetime — just alias.
            try (self.currentScope()).define(self.allocator, vd.name, init_t);
        }
    }

    fn lowerAssign(self: *Lowerer, idx: NodeIndex) anyerror!void {
        const a     = self.pool.get(idx).assign;
        const val_t = try self.lowerExpr(a.value);

        switch (self.pool.get(a.target).*) {
            .ident => |id| {
                if ((self.currentScope()).lookup(id.name)) |existing_t| {
                    // Re-assignment: update in place.
                    _ = (self.currentScope()).update(id.name, val_t);
                    _ = existing_t; // suppress unused warning
                } else {
                    // Implicit binding — infer lifetime from value.
                    const lt = self.temps.items[val_t].lifetime;
                    _ = self.lt_of_temp(val_t); // note the inferred lifetime
                    try (self.currentScope()).define(self.allocator, id.name, val_t);
                    _ = lt;
                }
            },
            .attr_ref => |ar| {
                // Look up declared lifetime of attr.
                const lt = if (self.sema.module_scope.symbols.get(ar.name)) |sym|
                    sym.lifetime
                else
                    .script;
                try self.emit(.{ .store_attr = .{ .name = ar.name, .src = val_t, .lifetime = lt } });
            },
            .field_access => |fa| {
                const obj_t = try self.lowerExpr(fa.object);
                try self.emit(.{ .field_set = .{ .object = obj_t, .field = fa.field, .src = val_t } });
            },
            else => {
                // Unsupported target — silently lower the expr for side-effects.
            },
        }
    }

    fn lowerIf(self: *Lowerer, idx: NodeIndex) anyerror!void {
        const is = self.pool.get(idx).if_stmt;
        const then_lbl = self.freshLabel();
        const else_lbl = self.freshLabel();
        const after_lbl = self.freshLabel();

        const cond_t = try self.lowerExpr(is.cond);
        try self.emit(.{ .branch = .{ .cond = cond_t, .then_lbl = then_lbl, .else_lbl = else_lbl } });

        try self.emit(.{ .label = then_lbl });
        try self.lowerBlock(is.then_block);
        try self.emit(.{ .jump = after_lbl });

        try self.emit(.{ .label = else_lbl });
        if (is.else_block != ast_mod.invalid_node) try self.lowerBlock(is.else_block);
        try self.emit(.{ .jump = after_lbl });

        try self.emit(.{ .label = after_lbl });
    }

    fn lowerWhile(self: *Lowerer, idx: NodeIndex) anyerror!void {
        const ws = self.pool.get(idx).while_stmt;
        const cond_lbl  = self.freshLabel();
        const body_lbl  = self.freshLabel();
        const after_lbl = self.freshLabel();

        try self.emit(.{ .jump = cond_lbl });
        try self.emit(.{ .label = cond_lbl });
        const cond_t = try self.lowerExpr(ws.cond);
        try self.emit(.{ .branch = .{ .cond = cond_t, .then_lbl = body_lbl, .else_lbl = after_lbl } });

        try self.emit(.{ .label = body_lbl });
        try self.lowerBlock(ws.body);
        try self.emit(.{ .jump = cond_lbl });

        try self.emit(.{ .label = after_lbl });
    }

    fn lowerForIn(self: *Lowerer, idx: NodeIndex) anyerror!void {
        const fi = self.pool.get(idx).for_in;
        const cond_lbl  = self.freshLabel();
        const body_lbl  = self.freshLabel();
        const after_lbl = self.freshLabel();

        // Lower the iter expression; if it's a range, extract lo and hi.
        const iter_node = self.pool.get(fi.iter);
        const loop_var_t: TempId = blk: {
            switch (iter_node.*) {
                .range => |r| {
                    const lo_t = try self.lowerExpr(r.lo);
                    const hi_t = try self.lowerExpr(r.hi);
                    // loop var = lo
                    const var_t = try self.freshTemp(.frame, sema_mod.T_INT);
                    try self.emit(.{ .copy = .{ .dest = var_t, .src = lo_t } });
                    // Define loop var in scope (push scope, will be shared with body)
                    try self.pushScope();
                    try (self.currentScope()).define(self.allocator, fi.var_name, var_t);

                    try self.emit(.{ .jump = cond_lbl });
                    try self.emit(.{ .label = cond_lbl });
                    const cmp_t = try self.freshTemp(.frame, sema_mod.T_BOOL);
                    try self.emit(.{ .binary = .{ .dest = cmp_t, .op = .lt, .left = var_t, .right = hi_t } });
                    try self.emit(.{ .branch = .{ .cond = cmp_t, .then_lbl = body_lbl, .else_lbl = after_lbl } });

                    try self.emit(.{ .label = body_lbl });
                    // Lower body stmts directly (we already pushed scope)
                    const body_block = self.pool.get(fi.body).block;
                    for (body_block.stmts) |stmt| try self.lowerStmt(stmt);

                    // Increment var_t
                    const one_t = try self.freshTemp(.frame, sema_mod.T_INT);
                    try self.emit(.{ .const_int = .{ .dest = one_t, .value = 1 } });
                    const inc_t = try self.freshTemp(.frame, sema_mod.T_INT);
                    try self.emit(.{ .binary = .{ .dest = inc_t, .op = .add, .left = var_t, .right = one_t } });
                    try self.emit(.{ .copy = .{ .dest = var_t, .src = inc_t } });
                    // update scope binding
                    _ = (self.currentScope()).update(fi.var_name, var_t);
                    try self.emit(.{ .jump = cond_lbl });
                    try self.emit(.{ .label = after_lbl });
                    self.popScope();
                    break :blk var_t;
                },
                else => {
                    // Non-range iter: lower as expr and skip (placeholder)
                    const iter_t = try self.lowerExpr(fi.iter);
                    break :blk iter_t;
                },
            }
        };
        _ = loop_var_t;
    }

    // ---- Expression lowering -----------------------------------------------

    fn lowerExpr(self: *Lowerer, idx: NodeIndex) anyerror!TempId {
        const lt      = self.sema.lifetimeOf(idx);
        const type_id = self.sema.nodeType(idx);

        switch (self.pool.get(idx).*) {
            // ---- Literals --------------------------------------------------
            .int_lit => |n| {
                const t = try self.freshTemp(lt, type_id);
                try self.emit(.{ .const_int = .{ .dest = t, .value = n.value } });
                return t;
            },
            .float_lit => |n| {
                const t = try self.freshTemp(lt, type_id);
                try self.emit(.{ .const_float = .{ .dest = t, .value = n.value } });
                return t;
            },
            .bool_lit => |n| {
                const t = try self.freshTemp(lt, type_id);
                try self.emit(.{ .const_bool = .{ .dest = t, .value = n.value } });
                return t;
            },
            .string_lit => |n| {
                const t = try self.freshTemp(lt, type_id);
                try self.emit(.{ .const_string = .{ .dest = t, .value = n.value } });
                return t;
            },
            .atom_lit => |n| {
                const t = try self.freshTemp(lt, type_id);
                try self.emit(.{ .const_atom = .{ .dest = t, .value = n.value } });
                return t;
            },

            // ---- Names -----------------------------------------------------
            .ident => |id| {
                if ((self.currentScope()).lookup(id.name)) |existing_t| {
                    // Return the existing temp directly — no copy needed.
                    return existing_t;
                }
                // Undefined — emit a poison zero temp and continue.
                const t = try self.freshTemp(.frame, 0);
                try self.emit(.{ .const_int = .{ .dest = t, .value = 0 } });
                return t;
            },
            .attr_ref => |ar| {
                const attr_lt = if (self.sema.module_scope.symbols.get(ar.name)) |sym|
                    sym.lifetime
                else
                    .script;
                const t = try self.freshTemp(attr_lt, type_id);
                try self.emit(.{ .load_attr = .{ .dest = t, .name = ar.name, .lifetime = attr_lt } });
                return t;
            },

            // ---- Arithmetic & logic ----------------------------------------
            .binary => |b| {
                const l = try self.lowerExpr(b.left);
                const r = try self.lowerExpr(b.right);
                const t = try self.freshTemp(lt, type_id);
                try self.emit(.{ .binary = .{ .dest = t, .op = b.op, .left = l, .right = r } });
                return t;
            },
            .unary => |u| {
                const operand = try self.lowerExpr(u.operand);
                const t = try self.freshTemp(lt, type_id);
                try self.emit(.{ .unary = .{ .dest = t, .op = u.op, .operand = operand } });
                return t;
            },

            // ---- Calls -----------------------------------------------------
            .call => |c| {
                // Extract callee name from ident node (direct call) or
                // namespaced field access like `utils.fn_name`.
                const callee_name = switch (self.pool.get(c.callee).*) {
                    .ident => |id| id.name,
                    .field_access => |fa| blk: {
                        // `module.fn` — use just the fn part as the C callee name.
                        if (self.pool.get(fa.object).* == .ident) {
                            break :blk fa.field;
                        }
                        break :blk "__indirect__";
                    },
                    else   => "__indirect__",
                };
                var args = std.ArrayListUnmanaged(TempId){};
                defer args.deinit(self.allocator);
                for (c.args) |a| try args.append(self.allocator, try self.lowerExpr(a));
                const is_void = (type_id == sema_mod.T_VOID);
                const t = if (is_void) ir_mod.invalid_temp else try self.freshTemp(lt, type_id);
                try self.emit(.{ .call = .{
                    .dest   = t,
                    .callee = callee_name,
                    .args   = try args.toOwnedSlice(self.allocator),
                } });
                return t;
            },
            .field_access => |fa| {
                const obj = try self.lowerExpr(fa.object);
                const t   = try self.freshTemp(lt, type_id);
                try self.emit(.{ .field_get = .{ .dest = t, .object = obj, .field = fa.field } });
                return t;
            },
            .index => |ix| {
                // Emit as a call to __index__ for now.
                const arr = try self.lowerExpr(ix.array);
                const i   = try self.lowerExpr(ix.idx);
                const t   = try self.freshTemp(lt, type_id);
                const arg_slice = try self.allocator.dupe(TempId, &.{ arr, i });
                try self.emit(.{ .call = .{ .dest = t, .callee = "__index__", .args = arg_slice } });
                return t;
            },

            // ---- Lifetime promotions ---------------------------------------
            .copy_to_script => |cts| {
                const src   = try self.lowerExpr(cts.expr);
                const from  = self.temps.items[src].lifetime;
                const t     = try self.freshTemp(.script, self.sema.nodeType(cts.expr));
                if (from != .script) {
                    try self.emit(.{ .promote = .{ .dest = t, .src = src, .from = from, .to = .script } });
                } else {
                    try self.emit(.{ .copy = .{ .dest = t, .src = src } });
                }
                return t;
            },
            .persist_copy => |pc| {
                const src  = try self.lowerExpr(pc.expr);
                const from = self.temps.items[src].lifetime;
                const t    = try self.freshTemp(.persistent, self.sema.nodeType(pc.expr));
                if (from != .persistent) {
                    try self.emit(.{ .promote = .{ .dest = t, .src = src, .from = from, .to = .persistent } });
                } else {
                    try self.emit(.{ .copy = .{ .dest = t, .src = src } });
                }
                return t;
            },

            // ---- Pattern matching ------------------------------------------
            .case_expr => |ce| {
                const scrutinee = try self.lowerExpr(ce.scrutinee);
                const result_t  = try self.freshTemp(lt, type_id);
                const after_lbl = self.freshLabel();

                for (ce.arms) |arm| {
                    const body_lbl = self.freshLabel();
                    const next_lbl = self.freshLabel();

                    // Emit pattern test.
                    const match_t = try self.lowerPatternTest(scrutinee, arm.pattern);
                    try self.emit(.{ .branch = .{ .cond = match_t, .then_lbl = body_lbl, .else_lbl = next_lbl } });

                    try self.emit(.{ .label = body_lbl });
                    try self.pushScope();
                    try self.lowerPatternBind(scrutinee, arm.pattern);
                    const arm_t = try self.lowerExprOrBlock(arm.body);
                    if (arm_t != invalid_temp) {
                        try self.emit(.{ .copy = .{ .dest = result_t, .src = arm_t } });
                    }
                    self.popScope();
                    try self.emit(.{ .jump = after_lbl });

                    try self.emit(.{ .label = next_lbl });
                }
                // Fall-through (no arm matched) — leave result_t at default 0.
                try self.emit(.{ .label = after_lbl });
                return result_t;
            },

            .block => {
                try self.lowerBlock(idx);
                const t = try self.freshTemp(.frame, 0);
                return t;
            },

            // ---- Match expression (enum/int switch) -------------------------
            .match_expr => |me| {
                const subj_t = try self.lowerExpr(me.subject);
                const result_t = try self.freshTemp(lt, type_id);
                const after_lbl = self.freshLabel();

                for (me.arms) |arm| {
                    const arm_lbl  = self.freshLabel();
                    const next_lbl = self.freshLabel();

                    // Generate pattern test
                    const match_t = try self.lowerMatchPatternTest(subj_t, arm.pattern);
                    try self.emit(.{ .branch = .{ .cond = match_t, .then_lbl = arm_lbl, .else_lbl = next_lbl } });

                    try self.emit(.{ .label = arm_lbl });
                    const arm_result = try self.lowerExpr(arm.body);
                    if (arm_result != invalid_temp) {
                        try self.emit(.{ .copy = .{ .dest = result_t, .src = arm_result } });
                    }
                    try self.emit(.{ .jump = after_lbl });

                    try self.emit(.{ .label = next_lbl });
                }
                try self.emit(.{ .label = after_lbl });
                return result_t;
            },

            // ---- Synthetic --------------------------------------------------
            .promote => |p| {
                const src  = try self.lowerExpr(p.src);
                const from = self.temps.items[src].lifetime;
                const t    = try self.freshTemp(p.dst_lt, self.sema.nodeType(p.src));
                if (from != p.dst_lt) {
                    try self.emit(.{ .promote = .{ .dest = t, .src = src, .from = from, .to = p.dst_lt } });
                } else {
                    try self.emit(.{ .copy = .{ .dest = t, .src = src } });
                }
                return t;
            },

            // ---- Range expression ------------------------------------------
            .range => |r| {
                // A range used as an expression (not as for-in iter): just return lo
                const lo_t = try self.lowerExpr(r.lo);
                _ = try self.lowerExpr(r.hi);
                return lo_t;
            },

            // ---- String interpolation --------------------------------------
            .str_interp => |si| {
                // Lower each part and chain with str_concat
                var acc_t: ?TempId = null;
                for (si.parts) |part| {
                    const part_t: TempId = switch (part) {
                        .literal => |s| blk: {
                            const t = try self.freshTemp(.frame, sema_mod.T_STRING);
                            try self.emit(.{ .const_string = .{ .dest = t, .value = s } });
                            break :blk t;
                        },
                        .expr => |e| blk: {
                            const e_t = try self.lowerExpr(e);
                            const e_ty = if (e_t < self.temps.items.len) self.temps.items[e_t].type_id else 0;
                            if (e_ty == sema_mod.T_STRING) {
                                break :blk e_t;
                            } else if (e_ty == sema_mod.T_FLOAT) {
                                const s_t = try self.freshTemp(.frame, sema_mod.T_STRING);
                                const args = try self.allocator.dupe(TempId, &.{e_t});
                                try self.emit(.{ .call = .{ .dest = s_t, .callee = "float_to_str", .args = args } });
                                break :blk s_t;
                            } else {
                                const s_t = try self.freshTemp(.frame, sema_mod.T_STRING);
                                const args = try self.allocator.dupe(TempId, &.{e_t});
                                try self.emit(.{ .call = .{ .dest = s_t, .callee = "int_to_str", .args = args } });
                                break :blk s_t;
                            }
                        },
                    };
                    if (acc_t == null) {
                        acc_t = part_t;
                    } else {
                        const new_t = try self.freshTemp(.frame, sema_mod.T_STRING);
                        const args = try self.allocator.dupe(TempId, &.{ acc_t.?, part_t });
                        try self.emit(.{ .call = .{ .dest = new_t, .callee = "str_concat", .args = args } });
                        acc_t = new_t;
                    }
                }
                if (acc_t) |t| return t;
                // Empty interp — return empty string
                const t = try self.freshTemp(.frame, sema_mod.T_STRING);
                try self.emit(.{ .const_string = .{ .dest = t, .value = "" } });
                return t;
            },

            // ---- Array literal ---------------------------------------------
            .array_lit => |al| {
                const n = al.elements.len;
                const cap_t = try self.freshTemp(.frame, sema_mod.T_INT);
                try self.emit(.{ .const_int = .{ .dest = cap_t, .value = @intCast(n) } });
                const arr_t = try self.freshTemp(.frame, sema_mod.T_ARRAY);
                const new_args = try self.allocator.dupe(TempId, &.{cap_t});
                try self.emit(.{ .call = .{ .dest = arr_t, .callee = "array_new", .args = new_args } });
                for (al.elements) |elem_idx| {
                    const elem_t = try self.lowerExpr(elem_idx);
                    const push_args = try self.allocator.dupe(TempId, &.{ arr_t, elem_t });
                    try self.emit(.{ .call = .{ .dest = invalid_temp, .callee = "array_push", .args = push_args } });
                }
                return arr_t;
            },

            // ---- Struct literal --------------------------------------------
            .struct_lit => |sl| {
                // Lower field values; return a placeholder zero temp
                for (sl.fields) |f| _ = try self.lowerExpr(f.value);
                const t = try self.freshTemp(.frame, 0);
                try self.emit(.{ .const_int = .{ .dest = t, .value = 0 } });
                return t;
            },

            // ---- Default ---------------------------------------------------
            else => {
                const t = try self.freshTemp(.frame, 0);
                try self.emit(.{ .const_int = .{ .dest = t, .value = 0 } });
                return t;
            },
        }
    }

    fn lowerExprOrBlock(self: *Lowerer, idx: NodeIndex) anyerror!TempId {
        return switch (self.pool.get(idx).*) {
            .block => blk: {
                try self.lowerBlock(idx);
                break :blk invalid_temp;
            },
            else => self.lowerExpr(idx),
        };
    }

    // ---- Pattern helpers ---------------------------------------------------

    /// Emit instructions that test whether `scrutinee` matches `pattern`.
    /// Returns a TempId holding a bool.
    fn lowerPatternTest(self: *Lowerer, scrutinee: TempId, pattern_idx: NodeIndex) anyerror!TempId {
        switch (self.pool.get(pattern_idx).*) {
            .pattern_wildcard, .pattern_bind => {
                // Always matches.
                const t = try self.freshTemp(.frame, sema_mod.T_BOOL);
                try self.emit(.{ .const_bool = .{ .dest = t, .value = true } });
                return t;
            },
            .pattern_atom => |pa| {
                // Compare scrutinee atom value.
                const atom_t = try self.freshTemp(.frame, sema_mod.T_ATOM);
                try self.emit(.{ .const_atom = .{ .dest = atom_t, .value = pa.value } });
                const t = try self.freshTemp(.frame, sema_mod.T_BOOL);
                try self.emit(.{ .binary = .{ .dest = t, .op = .eq, .left = scrutinee, .right = atom_t } });
                return t;
            },
            .pattern_lit => |pl| {
                const lit_t = try self.lowerExpr(pl.inner);
                const t     = try self.freshTemp(.frame, sema_mod.T_BOOL);
                try self.emit(.{ .binary = .{ .dest = t, .op = .eq, .left = scrutinee, .right = lit_t } });
                return t;
            },
            else => {
                const t = try self.freshTemp(.frame, sema_mod.T_BOOL);
                try self.emit(.{ .const_bool = .{ .dest = t, .value = true } });
                return t;
            },
        }
    }

    /// Emit a bool test for a match arm pattern (variant ident or wildcard).
    fn lowerMatchPatternTest(self: *Lowerer, subj: TempId, pattern_idx: NodeIndex) anyerror!TempId {
        switch (self.pool.get(pattern_idx).*) {
            .pattern_wildcard => {
                const t = try self.freshTemp(.frame, sema_mod.T_BOOL);
                try self.emit(.{ .const_bool = .{ .dest = t, .value = true } });
                return t;
            },
            .pattern_bind => |pb| {
                // Compare subject to the integer value of the named variant.
                // We use a const_int comparison; variant indices come from enum definition.
                // For now emit a compare by looking up the variant index from sema.
                const variant_idx = self.lookupEnumVariantIndex(pb.name);
                const val_t = try self.freshTemp(.frame, sema_mod.T_INT);
                try self.emit(.{ .const_int = .{ .dest = val_t, .value = variant_idx } });
                const t = try self.freshTemp(.frame, sema_mod.T_BOOL);
                try self.emit(.{ .binary = .{ .dest = t, .op = .eq, .left = subj, .right = val_t } });
                return t;
            },
            else => {
                const t = try self.freshTemp(.frame, sema_mod.T_BOOL);
                try self.emit(.{ .const_bool = .{ .dest = t, .value = true } });
                return t;
            },
        }
    }

    /// Look up the integer index of an enum variant from the sema enum table.
    /// Returns -1 (wildcard-like) if not found.
    fn lookupEnumVariantIndex(self: *Lowerer, variant_name: []const u8) i64 {
        // Iterate all enums to find which one has this variant
        var iter = self.sema.enums.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.*, 0..) |v, i| {
                if (std.mem.eql(u8, v, variant_name)) return @intCast(i);
            }
        }
        return 0;
    }

    /// Bind pattern variables in the current scope (called after test passes).
    fn lowerPatternBind(self: *Lowerer, scrutinee: TempId, pattern_idx: NodeIndex) anyerror!void {
        switch (self.pool.get(pattern_idx).*) {
            .pattern_bind => |pb| {
                try (self.currentScope()).define(self.allocator, pb.name, scrutinee);
            },
            else => {},
        }
    }

    // ---- Utilities ---------------------------------------------------------

    fn freshTemp(self: *Lowerer, lt: Lifetime, type_id: u32) !TempId {
        const id = self.next_temp;
        self.next_temp += 1;
        try self.temps.append(self.allocator, .{ .id = id, .lifetime = lt, .type_id = type_id });
        return id;
    }

    fn freshLabel(self: *Lowerer) LabelId {
        const id = self.next_label;
        self.next_label += 1;
        return id;
    }

    fn emit(self: *Lowerer, instr: Instr) !void {
        try self.instrs.append(self.allocator, instr);
    }

    fn endsWithTerminator(self: *const Lowerer) bool {
        if (self.instrs.items.len == 0) return false;
        return switch (self.instrs.items[self.instrs.items.len - 1]) {
            .ret, .ret_void, .jump => true,
            else => false,
        };
    }

    fn lt_of_temp(self: *const Lowerer, t: TempId) Lifetime {
        if (t < self.temps.items.len) return self.temps.items[t].lifetime;
        return .frame;
    }

    fn pushScope(self: *Lowerer) !void {
        const s = try self.allocator.create(LowerScope);
        s.* = .{ .parent = if (self.scope_stack.items.len > 0)
            self.scope_stack.items[self.scope_stack.items.len - 1]
        else
            null };
        try self.scope_stack.append(self.allocator, s);
    }

    fn popScope(self: *Lowerer) void {
        if (self.scope_stack.pop()) |s| {
            s.deinit(self.allocator);
            self.allocator.destroy(s);
        }
    }

    fn currentScope(self: *Lowerer) *LowerScope {
        const n = self.scope_stack.items.len;
        if (n > 0) return self.scope_stack.items[n - 1];
        // Should never happen during lowering; return a dummy scope.
        unreachable;
    }
};

// ---------------------------------------------------------------------------
// Free helpers
// ---------------------------------------------------------------------------

fn resolveLifetime(ann: ast_mod.LifetimeAnnotation, default: Lifetime) Lifetime {
    return switch (ann) {
        .inferred  => default,
        .explicit  => |l| l,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing  = std.testing;
const Lexer    = @import("lexer").Lexer;
const Parser   = @import("parser").Parser;
const DiagList = @import("diag").DiagList;

const TestLower = struct {
    arena:  std.heap.ArenaAllocator,
    module: IrModule,

    fn init(src: []const u8) !TestLower {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        const alloc = arena.allocator();

        var lex    = Lexer.init(src);
        const toks = try lex.tokenize(alloc);
        var pool   = AstPool.init(alloc);
        var diags  = DiagList.init(alloc);
        var parser = Parser.init(toks, &pool, &diags, alloc);
        const top  = try parser.parseFile();

        var sem = Sema.init(&pool, &diags, alloc);
        try sem.analyze(top);

        if (diags.hasErrors()) return error.SemaFailed;

        var lower = Lowerer.init(&pool, &sem, alloc);
        const mod = try lower.lower(top);

        return .{ .arena = arena, .module = mod };
    }

    fn deinit(self: *TestLower) void { self.arena.deinit(); }
};

test "lower integer literal function" {
    var tl = try TestLower.init(
        \\def f() do
        \\  42
        \\end
    );
    defer tl.deinit();
    try testing.expectEqual(@as(usize, 1), tl.module.functions.len);
    try testing.expectEqualStrings("f", tl.module.functions[0].name);
    try testing.expect(tl.module.functions[0].instrs.len > 0);
}

test "lower var_decl and ident read" {
    var tl = try TestLower.init(
        \\def f() do
        \\  x :: frame = 10
        \\  x
        \\end
    );
    defer tl.deinit();
    const fn0 = tl.module.functions[0];
    // Should have const_int for 10 and ret_void (x expr_stmt discards result).
    var found_const = false;
    for (fn0.instrs) |instr| {
        if (instr == .const_int and instr.const_int.value == 10) found_const = true;
    }
    try testing.expect(found_const);
}

test "lower copy_to_script emits promote" {
    var tl = try TestLower.init(
        \\def f() do
        \\  raw :: frame = 1
        \\  saved :: script = copy_to_script(raw)
        \\end
    );
    defer tl.deinit();
    const fn0 = tl.module.functions[0];
    var found_promote = false;
    for (fn0.instrs) |instr| {
        if (instr == .promote and instr.promote.to == .script) found_promote = true;
    }
    try testing.expect(found_promote);
}

test "lower @attr store and load" {
    var tl = try TestLower.init(
        \\@score :: script = 0
        \\def tick() do
        \\  v :: script = copy_to_script(1)
        \\  @score = v
        \\end
    );
    defer tl.deinit();
    // Attr init should have const_int 0.
    var found_init = false;
    for (tl.module.attr_init_instrs) |instr| {
        if (instr == .const_int and instr.const_int.value == 0) found_init = true;
    }
    try testing.expect(found_init);
    // Function should have store_attr.
    const fn0 = tl.module.functions[0];
    var found_store = false;
    for (fn0.instrs) |instr| {
        if (instr == .store_attr) found_store = true;
    }
    try testing.expect(found_store);
}

test "lower if/else emits branch and labels" {
    var tl = try TestLower.init(
        \\def f(x :: int) do
        \\  if x > 0 do
        \\    1
        \\  else
        \\    0
        \\  end
        \\end
    );
    defer tl.deinit();
    const fn0 = tl.module.functions[0];
    var found_branch = false;
    var label_count: usize = 0;
    for (fn0.instrs) |instr| {
        if (instr == .branch) found_branch = true;
        if (instr == .label)  label_count += 1;
    }
    try testing.expect(found_branch);
    try testing.expectEqual(@as(usize, 3), label_count); // then, else, after
}

test "lower while loop emits jump and branch" {
    var tl = try TestLower.init(
        \\def f() do
        \\  i :: frame = 0
        \\  while i < 10 do
        \\    i = i + 1
        \\  end
        \\end
    );
    defer tl.deinit();
    const fn0 = tl.module.functions[0];
    var found_jump = false;
    var found_branch = false;
    for (fn0.instrs) |instr| {
        if (instr == .jump)   found_jump   = true;
        if (instr == .branch) found_branch = true;
    }
    try testing.expect(found_jump);
    try testing.expect(found_branch);
}

test "lower full hello.chasm-style module" {
    var tl = try TestLower.init(
        \\@score :: script = 0
        \\@high_score :: persistent = 0
        \\defp compute_delta(dt :: f32) :: f32 do
        \\  speed :: frame = 9.8
        \\  speed * dt
        \\end
        \\def on_tick(dt :: f32) do
        \\  delta :: frame = compute_delta(dt)
        \\  saved :: script = copy_to_script(delta)
        \\  @score = saved
        \\end
        \\def on_save() do
        \\  final :: persistent = persist_copy(@score)
        \\  @high_score = final
        \\end
    );
    defer tl.deinit();
    try testing.expectEqual(@as(usize, 3), tl.module.functions.len);
    try testing.expectEqual(@as(usize, 2), tl.module.attrs.len);
}
