const runtime_abi = @import("kira_runtime_abi");
const source = @import("kira_source");

pub const ValueType = struct {
    kind: Kind,
    name: ?[]const u8 = null,
    construct_constraint: ?ConstructConstraint = null,

    pub const Kind = enum {
        void,
        integer,
        float,
        string,
        boolean,
        construct_any,
        array,
        raw_ptr,
        ffi_struct,
        enum_instance,
    };
};

pub const ConstructConstraint = struct {
    construct_name: []const u8,
};

pub const OwnershipMode = enum(u8) {
    owned,
    borrow_read,
    borrow_mut,
    move,
    copy,
};

pub const Program = struct {
    constructs: []Construct = &.{},
    construct_implementations: []ConstructImplementation = &.{},
    types: []TypeDecl = &.{},
    enums: []EnumTypeDecl = &.{},
    functions: []Function,
    entry_index: usize,
};

pub const Construct = struct {
    name: []const u8,
};

pub const ConstructImplementation = struct {
    type_name: []const u8,
    construct_constraint: ConstructConstraint,
    families: []const []const u8 = &.{},
    fields: []Field,
    has_content: bool,
    lifecycle_hooks: []LifecycleHook,
};

pub const LifecycleHook = struct {
    name: []const u8,
};

pub const TypeDecl = struct {
    name: []const u8,
    kind: TypeKind = .struct_decl,
    execution: runtime_abi.FunctionExecution = .inherited,
    fields: []Field,
    methods: []MethodMember = &.{},
    ffi: ?FfiTypeInfo = null,
};

pub const TypeKind = enum {
    class,
    struct_decl,
};

pub const MethodMember = struct {
    name: []const u8,
    function_id: u32,
    receiver_offset: u32,
};

pub const EnumTypeDecl = struct {
    name: []const u8,
    variants: []EnumVariantIr,
};

pub const EnumVariantIr = struct {
    name: []const u8,
    discriminant: u32,
    payload_ty: ?ValueType = null,
};

pub const Field = struct {
    name: []const u8,
    ty: ValueType,
};

pub const FfiTypeInfo = union(enum) {
    ffi_struct,
    pointer: PointerInfo,
    alias: AliasInfo,
    array: ArrayInfo,
    callback: CallbackInfo,
};

pub const PointerInfo = struct {
    target_name: []const u8,
};

pub const AliasInfo = struct {
    target: ValueType,
};

pub const ArrayInfo = struct {
    element: ValueType,
    count: usize,
};

pub const CallbackInfo = struct {
    params: []const ValueType,
    result: ValueType,
};

pub const ForeignFunction = struct {
    library_name: []const u8,
    symbol_name: []const u8,
    calling_convention: runtime_abi.CallingConvention = .c,
};

pub const Function = struct {
    id: u32,
    name: []const u8,
    is_async: bool = false,
    execution: runtime_abi.FunctionExecution,
    is_extern: bool = false,
    foreign: ?ForeignFunction = null,
    param_types: []const ValueType = &.{},
    param_ownership: []const OwnershipMode = &.{},
    return_type: ValueType = .{ .kind = .void },
    return_ownership: OwnershipMode = .owned,
    register_count: u32,
    local_count: u32,
    local_types: []const ValueType,
    /// Source-level names per local slot (index = local id), for the debugger's
    /// variables view. Empty for functions lowered without name info; entries may
    /// be "" for hidden/synthesized slots. Threaded HIR->IR->bytecode alongside
    /// `locations`.
    local_names: []const []const u8 = &.{},
    instructions: []Instruction,
    /// Source span per instruction, index-aligned with `instructions` when
    /// populated by the lowerer (see `instruction_buf.zig`). May be empty for
    /// synthesized functions (async rewrites, generated callbacks); consumers
    /// must treat `idx >= locations.len` and `{0,0}` spans as "no location".
    /// This is the debugger's source line-table source of truth in low IR.
    locations: []const source.Span = &.{},
};

pub const Instruction = union(enum) {
    const_int: ConstInt,
    const_float: ConstFloat,
    const_string: ConstString,
    const_bool: ConstBool,
    const_null_ptr: ConstNullPtr,
    const_function: ConstFunction,
    const_closure: ConstClosure,
    alloc_struct: AllocStruct,
    alloc_enum: AllocEnum,
    alloc_native_state: AllocNativeState,
    alloc_array: AllocArray,
    add: Binary,
    subtract: Binary,
    multiply: Binary,
    divide: Binary,
    modulo: Binary,
    bitwise: Bitwise,
    convert: Convert,
    compare: Compare,
    unary: Unary,
    store_local: StoreLocal,
    load_local: LoadLocal,
    local_ptr: LocalPtr,
    subobject_ptr: SubobjectPtr,
    field_ptr: FieldPtr,
    recover_native_state: RecoverNativeState,
    free_native_state: FreeNativeState,
    native_state_field_get: NativeStateFieldGet,
    native_state_field_set: NativeStateFieldSet,
    c_string_to_string: CStringToString,
    array_len: ArrayLen,
    string_len: StringLen,
    string_from_scalar: StringFromScalar,
    string_char_at: StringCharAt,
    string_substring: StringSubstring,
    string_index_of: StringIndexOf,
    array_get: ArrayGet,
    array_set: ArraySet,
    array_append: ArrayAppend,
    enum_tag: EnumTag,
    enum_payload: EnumPayload,
    load_indirect: LoadIndirect,
    store_indirect: StoreIndirect,
    copy_indirect: CopyIndirect,
    branch: Branch,
    jump: Jump,
    label: Label,
    print: Print,
    call: Call,
    call_virtual: VirtualCall,
    call_value: CallValue,
    ret: Return,
    // Async task spine (deferred execution). `task_spawn` captures the callee +
    // eagerly-evaluated args into a task object WITHOUT calling; the call runs
    // when the task is first driven (`task_await` joins it and yields the
    // result; `task_detach` drives and discards). `task_cancel` sets the
    // cooperative flag — a cancel observed before the first drive prevents the
    // call from running, and a later await traps. `task_spawn_ready` wraps a
    // pure, already-evaluated value as a completed task.
    task_spawn: TaskSpawn,
    task_spawn_ready: TaskSpawnReady,
    task_await: TaskAwait,
    task_cancel: TaskCancel,
    task_detach: TaskDetach,
    // Cooperative progress point: the executor runs the next queued task (if
    // any) before the current body continues.
    task_yield: TaskYield,
    // Task-frame slot access for state-machine (suspendable) task bodies: the
    // async transform externalizes a suspendable body's locals into a heap
    // frame (16-byte tag+payload slots on native, Value slots on the VM) so
    // the body can suspend by returning and later resume with its state
    // intact. `frame` is the register holding the frame pointer (the body's
    // single parameter); `slot` is a static index.
    frame_get: FrameGet,
    frame_set: FrameSet,
    // True when the task is no longer pending (complete, consumed, or
    // cancel-requested): joining it will not need to drive the executor. Used
    // by the async transform to turn `handle.await` inside a suspendable body
    // into a park-until-complete suspend point.
    task_is_complete: TaskIsComplete,
    // Park the current task for at least `ms` milliseconds (executor wakes it
    // when the deadline passes); blocks the thread outside a suspendable body.
    // Inside suspendable bodies the async transform pairs it with a
    // store-state + SUSPENDED return.
    task_sleep: TaskSleep,
    // Scope markers for drop elaboration. `scope_enter` opens a droppable scope
    // (loop body); `scope_exit` closes it, dropping owned values created within the
    // scope (loop-body locals + register temporaries) at iteration end so they are
    // not leaked until function exit. LLVM-backend only; the VM/bytecode path treats
    // them as no-ops (the VM reclaims via its own native-layout destructors).
    scope_enter: ScopeEnter,
    scope_exit: ScopeExit,
};

pub const TaskSpawn = struct {
    dst: u32,
    callee: u32,
    args: []const u32,
    /// The task's result type (the callee's return type).
    result_ty: ValueType,
    /// True when the callee was rewritten by the async state-machine
    /// transform: it takes a single frame pointer, returns a status
    /// (0 complete / 1 suspended), and the runtime must allocate a frame of
    /// `frame_slots` slots, seed slot 0 (resume state) with 0, and copy the
    /// args into slots 2.. before the first drive.
    suspendable: bool = false,
    frame_slots: u32 = 0,
};

/// Task-frame layout constants shared by the async transform and both
/// backends' runtimes: slot 0 = resume state, slot 1 = return value,
/// slots 2.. = the body's params then locals.
pub const frame_state_slot: u32 = 0;
pub const frame_result_slot: u32 = 1;
pub const frame_first_data_slot: u32 = 2;
/// Status values returned by a transformed suspendable body.
pub const task_status_complete: i64 = 0;
pub const task_status_suspended: i64 = 1;

pub const TaskSpawnReady = struct {
    dst: u32,
    value: u32,
    ty: ValueType,
};

pub const TaskAwait = struct {
    dst: u32,
    task: u32,
    ty: ValueType,
};

pub const TaskCancel = struct {
    task: u32,
};

pub const TaskDetach = struct {
    task: u32,
};

pub const TaskYield = struct {};

pub const TaskIsComplete = struct {
    dst: u32,
    task: u32,
};

pub const TaskSleep = struct {
    milliseconds: u32,
};

pub const FrameGet = struct {
    dst: u32,
    frame: u32,
    slot: u32,
    ty: ValueType,
};

pub const FrameSet = struct {
    frame: u32,
    slot: u32,
    src: u32,
    ty: ValueType,
};

pub const ScopeEnter = struct {};

pub const ScopeExit = struct {
    // Mapped IR local ids declared within the scope, to be dropped on scope exit.
    locals: []const u32,
};

pub const ConstInt = struct {
    dst: u32,
    value: i64,
};

pub const ConstFloat = struct {
    dst: u32,
    value: f64,
};

pub const ConstString = struct {
    dst: u32,
    value: []const u8,
};

pub const ConstBool = struct {
    dst: u32,
    value: bool,
};

pub const ConstNullPtr = struct {
    dst: u32,
};

pub const ConstFunction = struct {
    dst: u32,
    function_id: u32,
    representation: FunctionConstRepresentation = .callable_value,
};

pub const ConstClosure = struct {
    dst: u32,
    function_id: u32,
    captures: []const u32,
    capture_ownership: []const OwnershipMode = &.{},
};

pub const LocalPtr = struct {
    dst: u32,
    local: u32,
};

pub const FunctionConstRepresentation = enum {
    callable_value,
    native_callback,
};

pub const AllocStruct = struct {
    dst: u32,
    type_name: []const u8,
};

pub const AllocEnum = struct {
    dst: u32,
    enum_type_name: []const u8,
    discriminant: u32,
    payload_src: ?u32 = null,
};

pub const AllocNativeState = struct {
    dst: u32,
    src: u32,
    type_name: []const u8,
    type_id: u64,
};

pub const AllocArray = struct {
    dst: u32,
    len: u32,
    ty: ValueType = .{ .kind = .array },
};

pub const Binary = struct {
    dst: u32,
    lhs: u32,
    rhs: u32,
    // Set on `divide`/`modulo` when operands are an unsigned integer type (U8..U64),
    // selecting unsigned division/remainder. Add/subtract/multiply ignore it (wrap
    // identically for both signedness). Default false = signed, preserving old behavior.
    unsigned: bool = false,
};

// Numeric conversion between Int and Float (the `Int(x)` / `Float(x)` cast
// surface). `target` is the destination numeric kind; the source kind is read
// from the operand register's inferred type (LLVM) or its runtime tag (VM).
// Float->Int truncates toward zero; Int->Float is an exact widening; a cast to
// the kind a value already has is an identity copy.
pub const Convert = struct {
    dst: u32,
    src: u32,
    target: ValueType.Kind,
    // When true this is a bit-reinterpret (Float<->bits), not a value-preserving
    // numeric convert: the bit pattern is kept and only the type tag changes.
    reinterpret: bool = false,
};

pub const BitOp = enum {
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
};

pub const Bitwise = struct {
    dst: u32,
    lhs: u32,
    rhs: u32,
    op: BitOp,
    // Only meaningful for shift_right: true = logical (unsigned) shift, false =
    // arithmetic (sign-propagating). and/or/xor/shift_left are bit-identical
    // regardless of signedness.
    unsigned: bool = false,
};

pub const Compare = struct {
    dst: u32,
    lhs: u32,
    rhs: u32,
    op: CompareOp,
    // Set when operands are an unsigned integer type, selecting unsigned ordering
    // predicates for less/less_equal/greater/greater_equal. equal/not_equal are
    // sign-agnostic. Default false = signed.
    unsigned: bool = false,
};

pub const CompareOp = enum {
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

pub const Unary = struct {
    dst: u32,
    src: u32,
    op: UnaryOp,
};

pub const UnaryOp = enum {
    negate,
    not,
    bit_not,
};

pub const StoreLocal = struct {
    local: u32,
    src: u32,
    // Reborrow: bind the local as a non-owning alias of the source pointer
    // instead of cloning/owning it. Set when lowering `var r = t` where `t` is a
    // borrow (Rust reborrow semantics). The VM stores the slot borrowed (not freed
    // at frame exit); the LLVM backend's plain pointer store already aliases and its
    // drop pass leaves untracked (non-copy_indirect) locals alone.
    borrow: bool = false,
};

pub const LoadLocal = struct {
    dst: u32,
    local: u32,
    ownership: OwnershipMode = .borrow_read,
};

pub const SubobjectPtr = struct {
    dst: u32,
    base: u32,
    offset: u32,
};

pub const FieldPtr = struct {
    dst: u32,
    base: u32,
    base_type_name: []const u8,
    field_index: u32,
    field_ty: ValueType,
};

pub const RecoverNativeState = struct {
    dst: u32,
    state: u32,
    type_name: []const u8,
    type_id: u64,
};

pub const FreeNativeState = struct {
    state: u32,
};

pub const NativeStateFieldGet = struct {
    dst: u32,
    state: u32,
    field_index: u32,
    field_ty: ValueType,
    // Field move-out (see LoadIndirect.moved): the payload slot must be nulled
    // after the read and the destination becomes the owner.
    moved: bool = false,
};

pub const NativeStateFieldSet = struct {
    state: u32,
    field_index: u32,
    src: u32,
    field_ty: ValueType,
};

pub const CStringToString = struct {
    dst: u32,
    src: u32,
};

pub const ArrayLen = struct {
    dst: u32,
    array: u32,
};

pub const StringLen = struct {
    dst: u32,
    string: u32,
};

// Scalar -> String conversion (`String(x)`). `source` selects the byte format.
pub const StringFromScalarSource = enum { integer, float, boolean };
pub const StringFromScalar = struct {
    dst: u32,
    src: u32,
    source: StringFromScalarSource,
};

// `s.charAt(i)` -> Int code unit. Out-of-bounds traps (VM) / mirrors array
// indexing per backend.
pub const StringCharAt = struct {
    dst: u32,
    string: u32,
    index: u32,
};

// `s.substring(start, end)` -> fresh owned String (half-open range).
pub const StringSubstring = struct {
    dst: u32,
    string: u32,
    start: u32,
    end: u32,
};

// `s.indexOf(needle)` -> Int offset, or -1 when absent.
pub const StringIndexOf = struct {
    dst: u32,
    string: u32,
    needle: u32,
};

pub const ArrayGet = struct {
    dst: u32,
    array: u32,
    index: u32,
    ty: ValueType,
    // When set, the element feeds only a non-escaping read and the array cannot be
    // mutated/freed while the alias is live, so the interpreter aliases a managed
    // element instead of deep-cloning it (matching the native backend, which never
    // copies a borrowed element). Set by the IR peepholes for `arr[i].scalar`.
    borrow: bool = false,
    // Checker-verified element DRAIN from an OWNED array: dst takes the
    // element's value as its owner and the slot tombstones to VOID (array
    // release skips it; a later read of the drained slot traps). Used by
    // consuming-receiver dispatch over `[some T]` children.
    moved: bool = false,
};

pub const ArraySet = struct {
    array: u32,
    index: u32,
    src: u32,
};

pub const ArrayAppend = struct {
    array: u32,
    src: u32,
};

pub const EnumTag = struct {
    dst: u32,
    src: u32,
};

pub const EnumPayload = struct {
    dst: u32,
    src: u32,
    payload_ty: ValueType,
};

pub const LoadIndirect = struct {
    dst: u32,
    ptr: u32,
    ty: ValueType,
    // True for a checker-verified field MOVE-OUT (`let previous = obj.nodes`):
    // ownership transfers to `dst`, and the backend nulls the field storage so
    // the owner's destructor / a later field overwrite cannot double-free the
    // moved value. False for plain borrowed reads (`obj.ids[i]`).
    moved: bool = false,
};

pub const StoreIndirect = struct {
    ptr: u32,
    src: u32,
    ty: ValueType,
};

pub const CopyIndirect = struct {
    dst_ptr: u32,
    src_ptr: u32,
    type_name: []const u8,
};

pub const Branch = struct {
    condition: u32,
    true_label: u32,
    false_label: u32,
};

pub const Jump = struct {
    label: u32,
};

pub const Label = struct {
    id: u32,
};

pub const Print = struct {
    src: u32,
    ty: ValueType,
};

pub const Call = struct {
    callee: u32,
    args: []const u32,
    dst: ?u32 = null,
};

pub const VirtualCall = struct {
    receiver: u32,
    static_type_name: []const u8,
    method_name: []const u8,
    args: []const u32,
    return_ty: ValueType,
    dst: ?u32 = null,
};

pub const CallValue = struct {
    callee: u32,
    args: []const u32,
    param_types: []const ValueType,
    // Per-parameter ownership so the backend drop pass can escape arguments consumed by an
    // owned/move parameter (mirrors Function.param_ownership). Empty => treat all as owned.
    param_ownership: []const OwnershipMode = &.{},
    return_type: ValueType,
    dst: ?u32 = null,
};

pub const Return = struct {
    src: ?u32 = null,
};
