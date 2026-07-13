const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const model = @import("kira_semantics_model");
const shared = @import("lower_shared.zig");

pub fn validateDirectFfiBoundary(
    ctx: *shared.Context,
    declaration_name: []const u8,
    declaration_header: shared.FunctionHeader,
    body: []const model.Statement,
    all_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !void {
    if (declaration_header.execution == .native) return;
    // The VM executes direct FFI through LibFFI (see kira_vm_runtime/src/vm_ffi.zig),
    // so the @Native requirement is lifted for that target. Other backends still
    // require an @Native boundary to marshal the call.
    if (ctx.allow_runtime_direct_ffi) return;

    const lookup = HeaderLookup{ .by_name = all_headers, .extern_by_id = try externIndex(ctx, all_headers) };
    for (body) |statement| {
        if (findDirectFfiUseInStatement(statement, lookup)) |use| {
            try emitDirectFfiRequiresNative(ctx, declaration_name, declaration_header.span, use);
            return error.DiagnosticsEmitted;
        }
    }
}

const DirectFfiUse = struct {
    symbol_name: []const u8,
    span: source_pkg.Span,
};

/// Header lookup passed through the boundary walk: the by-name map for exact/leaf
/// name resolution, plus a by-id index restricted to extern headers so a call's
/// fallback id resolution is O(1) instead of a full scan of every function header.
const HeaderLookup = struct {
    by_name: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
    extern_by_id: *const std.AutoHashMapUnmanaged(u32, shared.FunctionHeader),
};

/// Build (once, memoized on `ctx`) the extern-header-by-id index from the full
/// name-keyed header map. Extern declarations are few, so the index is small; the
/// map is stable for the whole lowering pass.
fn externIndex(
    ctx: *shared.Context,
    all_headers: *const std.StringHashMapUnmanaged(shared.FunctionHeader),
) !*const std.AutoHashMapUnmanaged(u32, shared.FunctionHeader) {
    if (ctx.extern_headers_by_id == null) {
        var map = std.AutoHashMapUnmanaged(u32, shared.FunctionHeader){};
        errdefer map.deinit(ctx.allocator);
        var it = all_headers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.is_extern) {
                try map.put(ctx.allocator, entry.value_ptr.id, entry.value_ptr.*);
            }
        }
        ctx.extern_headers_by_id = map;
    }
    return &ctx.extern_headers_by_id.?;
}

fn findDirectFfiUseInStatement(
    statement: model.Statement,
    lookup: HeaderLookup,
) ?DirectFfiUse {
    switch (statement) {
        .let_stmt => |node| if (node.value) |value| return findDirectFfiUseInExpr(value.*, lookup),
        .assign_stmt => |node| {
            if (findDirectFfiUseInExpr(node.target.*, lookup)) |use| return use;
            if (findDirectFfiUseInExpr(node.value.*, lookup)) |use| return use;
        },
        .expr_stmt => |node| return findDirectFfiUseInExpr(node.expr.*, lookup),
        .if_stmt => |node| {
            if (findDirectFfiUseInExpr(node.condition.*, lookup)) |use| return use;
            if (findDirectFfiUseInStatements(node.then_body, lookup)) |use| return use;
            if (node.else_body) |else_body| if (findDirectFfiUseInStatements(else_body, lookup)) |use| return use;
        },
        .for_stmt => |node| {
            if (findDirectFfiUseInExpr(node.iterator.*, lookup)) |use| return use;
            if (findDirectFfiUseInStatements(node.body, lookup)) |use| return use;
        },
        .while_stmt => |node| {
            if (findDirectFfiUseInExpr(node.condition.*, lookup)) |use| return use;
            if (findDirectFfiUseInStatements(node.body, lookup)) |use| return use;
        },
        .match_stmt => |node| {
            if (findDirectFfiUseInExpr(node.subject.*, lookup)) |use| return use;
            for (node.arms) |arm| {
                if (findDirectFfiUseInMatchPattern(arm.pattern, lookup)) |use| return use;
                if (arm.guard) |guard| if (findDirectFfiUseInExpr(guard.*, lookup)) |use| return use;
                if (findDirectFfiUseInStatements(arm.body, lookup)) |use| return use;
            }
        },
        .switch_stmt => |node| {
            if (findDirectFfiUseInExpr(node.subject.*, lookup)) |use| return use;
            for (node.cases) |case| {
                if (findDirectFfiUseInExpr(case.pattern.*, lookup)) |use| return use;
                if (findDirectFfiUseInStatements(case.body, lookup)) |use| return use;
            }
            if (node.default_body) |default_body| if (findDirectFfiUseInStatements(default_body, lookup)) |use| return use;
        },
        .return_stmt => |node| if (node.value) |value| return findDirectFfiUseInExpr(value.*, lookup),
        .break_stmt, .continue_stmt => {},
    }
    return null;
}

fn findDirectFfiUseInStatements(
    statements: []const model.Statement,
    lookup: HeaderLookup,
) ?DirectFfiUse {
    for (statements) |statement| {
        if (findDirectFfiUseInStatement(statement, lookup)) |use| return use;
    }
    return null;
}

fn findDirectFfiUseInExpr(
    expr: model.Expr,
    lookup: HeaderLookup,
) ?DirectFfiUse {
    switch (expr) {
        .function_ref => |node| {
            if (externHeaderForFunctionRef(node, lookup)) |header| {
                return .{
                    .symbol_name = directFfiSymbolName(node.name, header),
                    .span = node.span,
                };
            }
        },
        .c_string_to_string => |node| return findDirectFfiUseInExpr(node.value.*, lookup),
        .array_len => |node| return findDirectFfiUseInExpr(node.object.*, lookup),
        .string_len => |node| return findDirectFfiUseInExpr(node.object.*, lookup),
        .string_from_scalar => |node| return findDirectFfiUseInExpr(node.operand.*, lookup),
        .string_char_at => |node| {
            if (findDirectFfiUseInExpr(node.object.*, lookup)) |use| return use;
            return findDirectFfiUseInExpr(node.index.*, lookup);
        },
        .string_substring => |node| {
            if (findDirectFfiUseInExpr(node.object.*, lookup)) |use| return use;
            if (findDirectFfiUseInExpr(node.start.*, lookup)) |use| return use;
            return findDirectFfiUseInExpr(node.end.*, lookup);
        },
        .string_index_of => |node| {
            if (findDirectFfiUseInExpr(node.object.*, lookup)) |use| return use;
            return findDirectFfiUseInExpr(node.needle.*, lookup);
        },
        .field => |node| return findDirectFfiUseInExpr(node.object.*, lookup),
        .native_state => |node| return findDirectFfiUseInExpr(node.value.*, lookup),
        .native_user_data => |node| return findDirectFfiUseInExpr(node.state.*, lookup),
        .native_recover => |node| return findDirectFfiUseInExpr(node.value.*, lookup),
        .native_state_free => |node| return findDirectFfiUseInExpr(node.state.*, lookup),
        .binary => |node| {
            if (findDirectFfiUseInExpr(node.lhs.*, lookup)) |use| return use;
            if (findDirectFfiUseInExpr(node.rhs.*, lookup)) |use| return use;
        },
        .unary => |node| return findDirectFfiUseInExpr(node.operand.*, lookup),
        .cast => |node| return findDirectFfiUseInExpr(node.operand.*, lookup),
        .conditional => |node| {
            if (findDirectFfiUseInExpr(node.condition.*, lookup)) |use| return use;
            if (findDirectFfiUseInExpr(node.then_expr.*, lookup)) |use| return use;
            if (findDirectFfiUseInExpr(node.else_expr.*, lookup)) |use| return use;
        },
        .construct => |node| {
            for (node.fields) |field| {
                if (findDirectFfiUseInExpr(field.value.*, lookup)) |use| return use;
            }
        },
        .construct_enum_variant => |node| {
            if (node.payload) |payload| return findDirectFfiUseInExpr(payload.*, lookup);
        },
        .call => |node| {
            if (externHeaderForCall(node, lookup)) |header| {
                return .{
                    .symbol_name = directFfiSymbolName(node.callee_name, header),
                    .span = node.span,
                };
            }
            for (node.args) |arg| {
                if (findDirectFfiUseInExpr(arg.*, lookup)) |use| return use;
            }
            if (node.trailing_builder) |builder| {
                if (findDirectFfiUseInBuilder(builder, lookup)) |use| return use;
            }
        },
        .virtual_call => |node| {
            if (findDirectFfiUseInExpr(node.receiver.*, lookup)) |use| return use;
            for (node.args) |arg| {
                if (findDirectFfiUseInExpr(arg.*, lookup)) |use| return use;
            }
        },
        .call_value => |node| {
            if (findDirectFfiUseInExpr(node.callee.*, lookup)) |use| return use;
            for (node.args) |arg| {
                if (findDirectFfiUseInExpr(arg.*, lookup)) |use| return use;
            }
        },
        .callback => |node| return findDirectFfiUseInStatements(node.body, lookup),
        .array => |node| {
            for (node.elements) |element| {
                if (findDirectFfiUseInExpr(element.*, lookup)) |use| return use;
            }
        },
        .builder_array => |node| return findDirectFfiUseInBuilder(node.builder, lookup),
        .index => |node| {
            if (findDirectFfiUseInExpr(node.object.*, lookup)) |use| return use;
            if (findDirectFfiUseInExpr(node.index.*, lookup)) |use| return use;
        },
        .task_spawn => |node| {
            for (node.args) |arg| {
                if (findDirectFfiUseInExpr(arg.*, lookup)) |use| return use;
            }
        },
        .task_spawn_ready => |node| return findDirectFfiUseInExpr(node.value.*, lookup),
        .task_await => |node| return findDirectFfiUseInExpr(node.task.*, lookup),
        .task_cancel => |node| return findDirectFfiUseInExpr(node.task.*, lookup),
        .task_detach => |node| return findDirectFfiUseInExpr(node.task.*, lookup),
        .task_sleep => |node| return findDirectFfiUseInExpr(node.milliseconds.*, lookup),
        .task_yield,
        .integer,
        .float,
        .string,
        .boolean,
        .null_ptr,
        .local,
        .namespace_ref,
        .parent_view,
        => {},
    }
    return null;
}

fn findDirectFfiUseInMatchPattern(
    pattern: model.MatchPattern,
    lookup: HeaderLookup,
) ?DirectFfiUse {
    return switch (pattern) {
        .variant => |node| if (node.inner) |inner| findDirectFfiUseInMatchPattern(inner.*, lookup) else null,
        .binding => null,
    };
}

fn findDirectFfiUseInBuilder(
    builder: model.BuilderBlock,
    lookup: HeaderLookup,
) ?DirectFfiUse {
    for (builder.items) |item| {
        switch (item) {
            .expr => |node| if (findDirectFfiUseInExpr(node.expr.*, lookup)) |use| return use,
            .if_item => |node| {
                if (findDirectFfiUseInExpr(node.condition.*, lookup)) |use| return use;
                if (findDirectFfiUseInBuilder(node.then_block, lookup)) |use| return use;
                if (node.else_block) |else_block| if (findDirectFfiUseInBuilder(else_block, lookup)) |use| return use;
            },
            .for_item => |node| {
                if (findDirectFfiUseInExpr(node.iterator.*, lookup)) |use| return use;
                if (findDirectFfiUseInBuilder(node.body, lookup)) |use| return use;
            },
            .switch_item => |node| {
                if (findDirectFfiUseInExpr(node.subject.*, lookup)) |use| return use;
                for (node.cases) |case| {
                    if (findDirectFfiUseInExpr(case.pattern.*, lookup)) |use| return use;
                    if (findDirectFfiUseInBuilder(case.body, lookup)) |use| return use;
                }
                if (node.default_block) |default_block| if (findDirectFfiUseInBuilder(default_block, lookup)) |use| return use;
            },
        }
    }
    return null;
}

fn externHeaderForCall(
    call: model.hir.CallExpr,
    lookup: HeaderLookup,
) ?shared.FunctionHeader {
    if (externHeaderByName(lookup, call.callee_name)) |header| return header;
    if (call.function_id) |function_id| {
        if (externHeaderById(lookup, function_id)) |header| return header;
    }
    return null;
}

fn externHeaderForFunctionRef(
    function_ref: model.hir.FunctionRefExpr,
    lookup: HeaderLookup,
) ?shared.FunctionHeader {
    if (externHeaderByName(lookup, function_ref.name)) |header| return header;
    return externHeaderById(lookup, function_ref.function_id);
}

fn externHeaderById(
    lookup: HeaderLookup,
    function_id: u32,
) ?shared.FunctionHeader {
    return lookup.extern_by_id.get(function_id);
}

fn externHeaderByName(
    lookup: HeaderLookup,
    name: []const u8,
) ?shared.FunctionHeader {
    const leaf = qualifiedLeaf(name);
    const header = lookup.by_name.get(name) orelse lookup.by_name.get(leaf) orelse return null;
    return if (header.is_extern) header else null;
}

fn directFfiSymbolName(callee_name: []const u8, header: shared.FunctionHeader) []const u8 {
    if (header.foreign) |foreign| return foreign.symbol_name;
    return qualifiedLeaf(callee_name);
}

fn qualifiedLeaf(name: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[index + 1 ..];
}

fn emitDirectFfiRequiresNative(
    ctx: *shared.Context,
    declaration_name: []const u8,
    declaration_span: source_pkg.Span,
    use: DirectFfiUse,
) !void {
    try diagnostics.appendOwned(ctx.allocator, ctx.diagnostics, .{
        .severity = .@"error",
        .code = "KSEM093",
        .title = "direct FFI requires @Native",
        .message = try std.fmt.allocPrint(
            ctx.allocator,
            "The declaration '{s}' directly uses FFI-bound symbol '{s}', but the VM cannot execute FFI directly.",
            .{ declaration_name, use.symbol_name },
        ),
        .labels = &.{
            diagnostics.primaryLabel(use.span, "direct FFI-bound symbol use"),
            diagnostics.secondaryLabel(declaration_span, "this declaration is not marked @Native"),
        },
        .help = "Mark this declaration with @Native, or move the direct FFI use into a small @Native helper and call that helper instead.",
    });
}
