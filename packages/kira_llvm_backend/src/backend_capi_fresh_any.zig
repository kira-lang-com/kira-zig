// Fresh-Any return analysis for the LLVM C-API backend's drop driver.
//
// KIRA_MEMORY_MODEL.md §3: plain-call construct_any (type-erased / Any)
// results are not tracked by default, because a callee may return a BORROWED
// alias (a field read, a parameter) and `ret` never deep-clones Any values —
// tracking an alias would have the caller free storage the real owner still
// holds. That default leaked every widget tree a `body`/factory function
// returned: those results are always freshly built, single-owner values.
//
// This analysis proves, per function, that every construct_any return is a
// FRESH OWNED value — one the callee frame itself produced and escaped — so
// the call site can track the result as a .struct_ptr drop (runtime-typed
// destroy at scope exit) without any clone. Fresh sources are:
//
//   - alloc_struct results (construct literals),
//   - construct-family / static virtual call results returning construct_any
//     (the model already treats those as single-owner at every call site),
//   - plain-call results whose callee is itself proven fresh (fixed point),
//   - values flowing through locals ALL of whose stores are fresh and
//     non-borrow.
//
// Everything else — parameters, field reads, array elements, native-state
// slots — is not fresh, and one non-fresh return path marks the whole
// function non-fresh (its results stay untracked: the documented
// conservative-leak fallback). The fixed point starts pessimistic (nothing
// fresh), so recursion and cycles resolve to non-fresh, never to an unsound
// "fresh".
const std = @import("std");
const ir = @import("kira_ir");

pub const FreshAnyReturns = struct {
    set: std.AutoHashMapUnmanaged(u32, void) = .{},

    pub fn deinit(self: *FreshAnyReturns, allocator: std.mem.Allocator) void {
        self.set.deinit(allocator);
    }

    pub fn contains(self: FreshAnyReturns, function_id: u32) bool {
        return self.set.contains(function_id);
    }
};

pub fn compute(allocator: std.mem.Allocator, program: *const ir.Program) !FreshAnyReturns {
    var result = FreshAnyReturns{};
    errdefer result.deinit(allocator);

    // Only construct_any-returning functions participate.
    var changed = true;
    while (changed) {
        changed = false;
        for (program.functions) |function_decl| {
            if (function_decl.return_type.kind != .construct_any) continue;
            if (result.set.contains(function_decl.id)) continue;
            if (try functionReturnsFresh(allocator, program, function_decl, &result)) {
                try result.set.put(allocator, function_decl.id, {});
                changed = true;
            }
        }
    }
    return result;
}

fn functionReturnsFresh(
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    function_decl: ir.Function,
    known: *const FreshAnyReturns,
) !bool {
    // reg_fresh: register was last produced by a fresh source on EVERY write
    // (a register rewritten by a non-fresh producer drops out — AND semantics,
    // safe for the reuse-across-branches the register allocator may emit).
    // local_ok/local_stored: a local is fresh only if every non-borrow store
    // into it is fresh and no borrow store exists.
    const reg_fresh = try allocator.alloc(bool, function_decl.register_count);
    defer allocator.free(reg_fresh);
    const reg_written = try allocator.alloc(bool, function_decl.register_count);
    defer allocator.free(reg_written);
    const local_ok = try allocator.alloc(bool, function_decl.local_count);
    defer allocator.free(local_ok);
    const local_stored = try allocator.alloc(bool, function_decl.local_count);
    defer allocator.free(local_stored);
    @memset(local_ok, true);
    @memset(local_stored, false);

    // Two passes: locals depend on registers (stores) and registers on locals
    // (loads). The second pass sees the final local verdicts; a load in pass 1
    // that optimistically trusted a local invalidated later is corrected in
    // pass 2 because local_ok only ever tightens.
    var pass: u2 = 0;
    while (pass < 2) : (pass += 1) {
        @memset(reg_fresh, false);
        @memset(reg_written, false);
        for (function_decl.instructions) |instruction| {
            switch (instruction) {
                .alloc_struct => |v| markReg(reg_fresh, reg_written, v.dst, true),
                .call => |v| {
                    const dst = v.dst orelse continue;
                    const callee = functionById(program, v.callee);
                    const fresh = callee != null and
                        callee.?.return_type.kind == .construct_any and
                        known.contains(v.callee);
                    markReg(reg_fresh, reg_written, dst, fresh);
                },
                .call_virtual => |v| {
                    const dst = v.dst orelse continue;
                    markReg(reg_fresh, reg_written, dst, virtualCallReturnsFresh(program, v, known));
                },
                .store_local => |v| {
                    if (v.local >= local_ok.len) continue;
                    local_stored[v.local] = true;
                    const src_fresh = v.src < reg_fresh.len and reg_fresh[v.src];
                    if (v.borrow or !src_fresh) local_ok[v.local] = false;
                },
                .load_local => |v| {
                    const fresh = v.local < local_ok.len and local_ok[v.local] and local_stored[v.local];
                    markReg(reg_fresh, reg_written, v.dst, fresh);
                },
                else => |other| {
                    // Any other producer writing a register is non-fresh.
                    if (instructionDst(other)) |dst| markReg(reg_fresh, reg_written, dst, false);
                },
            }
        }
    }

    var saw_return = false;
    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .ret => |v| {
                const src = v.src orelse return false;
                saw_return = true;
                if (src >= reg_fresh.len or !reg_fresh[src]) return false;
            },
            else => {},
        }
    }
    return saw_return;
}

// A virtual call's Any result is fresh only when EVERY dispatch target it can
// reach is proven fresh — mirrors backend_capi_calls.lowerCallVirtual so the
// analysis matches the code that actually runs:
//   - a concrete `static_type_name` routes to lowerStaticVirtualCall, a normal
//     call to the resolved method, which can return a borrowed Any alias, so it
//     is fresh only if that resolved callee is proven fresh (same as `.call`);
//   - otherwise the construct-family dispatch calls one candidate per matching
//     implementation, fresh only if all candidates are proven fresh (any
//     borrowed-returning candidate makes tracking the result a double-free).
fn virtualCallReturnsFresh(program: *const ir.Program, v: ir.VirtualCall, known: *const FreshAnyReturns) bool {
    if (v.return_ty.kind != .construct_any) return false;
    if (findTypeDecl(program, v.static_type_name)) |type_decl| {
        const fn_id = methodFunctionId(type_decl, v.method_name) orelse return false;
        return known.contains(fn_id);
    }
    var matched = false;
    for (program.construct_implementations) |implementation| {
        if (!implementationSatisfiesFamily(implementation, v.static_type_name)) continue;
        const fn_id = methodFunctionIdByType(program, implementation.type_name, v.method_name) orelse continue;
        matched = true;
        if (!known.contains(fn_id)) return false;
    }
    return matched;
}

fn findTypeDecl(program: *const ir.Program, name: []const u8) ?ir.TypeDecl {
    for (program.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

fn methodFunctionId(type_decl: ir.TypeDecl, method_name: []const u8) ?u32 {
    for (type_decl.methods) |method_decl| {
        if (std.mem.eql(u8, method_decl.name, method_name)) return method_decl.function_id;
    }
    return null;
}

fn methodFunctionIdByType(program: *const ir.Program, type_name: []const u8, method_name: []const u8) ?u32 {
    return methodFunctionId(findTypeDecl(program, type_name) orelse return null, method_name);
}

fn implementationSatisfiesFamily(implementation: ir.ConstructImplementation, family: []const u8) bool {
    for (implementation.families) |candidate| {
        if (std.mem.eql(u8, candidate, family)) return true;
    }
    return std.mem.eql(u8, implementation.construct_constraint.construct_name, family);
}

fn markReg(reg_fresh: []bool, reg_written: []bool, dst: u32, fresh: bool) void {
    if (dst >= reg_fresh.len) return;
    // AND across rewrites: once any writer is non-fresh, the register stays non-fresh.
    reg_fresh[dst] = if (reg_written[dst]) reg_fresh[dst] and fresh else fresh;
    reg_written[dst] = true;
}

fn functionById(program: *const ir.Program, id: u32) ?ir.Function {
    for (program.functions) |function_decl| {
        if (function_decl.id == id) return function_decl;
    }
    return null;
}

// Best-effort dst extraction for the non-fresh default arm. Instructions
// without a plain `dst: u32` field simply return null — they cannot produce a
// register we would have marked fresh anyway (markReg only ever LOWERS a
// register's freshness here).
fn instructionDst(instruction: ir.Instruction) ?u32 {
    return switch (instruction) {
        inline else => |v| if (@hasField(@TypeOf(v), "dst")) v.dst else null,
    };
}
