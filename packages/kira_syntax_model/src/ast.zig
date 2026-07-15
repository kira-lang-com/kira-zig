const std = @import("std");
const Span = @import("kira_source").Span;
const exprs = @import("ast_exprs.zig");

pub const Program = struct {
    imports: []ImportDecl,
    decls: []Decl,
    functions: []FunctionDecl,
    import_origins: []DeclOrigin = &.{},
    decl_origins: []DeclOrigin = &.{},
    function_origins: []DeclOrigin = &.{},
};

pub const DeclOrigin = struct {
    package_name: ?[]const u8 = null,
    source_path: []const u8 = "",
    // For an import statement's origin: the manifest name of the package that OWNS the
    // imported module, recorded when the module root a file writes (`import UI`) differs
    // from that package name (e.g. `Package UILibrary { moduleRoot "UI" }`). Null when the
    // module root already matches its package name and for non-import origins. The
    // file-scope import gate keys dependency symbols by owner package name, so the per-file
    // import index records this owner alongside the written module root.
    module_owner_package: ?[]const u8 = null,
};

pub const Decl = union(enum) {
    annotation_decl: AnnotationDecl,
    capability_decl: CapabilityDecl,
    enum_decl: EnumDecl,
    type_alias_decl: TypeAliasDecl,
    function_decl: FunctionDecl,
    type_decl: TypeDecl,
    construct_decl: ConstructDecl,
    construct_form_decl: ConstructFormDecl,
    fail_test_decl: FailTestDecl,
    extend_decl: ExtendDecl,
    macro_decl: MacroDecl,
    // A top-level `name!(args)` invocation of a function-position procedural macro. The
    // macro-expansion pass replaces it with the declarations the macro generates.
    macro_invocation: CallExpr,
};

// `extend Widget { function padding(...) -> Widget { ... } }` adds fluent modifier functions to a
// construct family. The target is a construct name; members are functions. This is the external,
// fluent-modifier surface (e.g. `.padding(...)`), distinct from the core Widget->Node bridge.
pub const ExtendDecl = struct {
    annotations: []const Annotation,
    construct_name: QualifiedName,
    members: []BodyMember,
    span: Span,
};

pub const ImportDecl = struct {
    module_name: QualifiedName,
    alias: ?[]const u8,
    span: Span,
};

pub const NameSegment = struct {
    text: []const u8,
    span: Span,
};

pub const QualifiedName = struct {
    segments: []NameSegment,
    span: Span,
};

pub const Annotation = struct {
    name: QualifiedName,
    args: []AnnotationArg,
    block: ?AnnotationBlock,
    span: Span,
};

pub const AnnotationArg = struct {
    label: ?[]const u8,
    value: *Expr,
    span: Span,
};

pub const AnnotationBlock = struct {
    entries: []AnnotationBlockEntry,
    span: Span,
};

pub const AnnotationBlockEntry = union(enum) {
    value: AnnotationBlockValue,
    field: AnnotationBlockField,
};

pub const AnnotationBlockValue = struct {
    value: *Expr,
    span: Span,
};

pub const AnnotationBlockField = struct {
    name: []const u8,
    value: *Expr,
    span: Span,
};

pub const AnnotationDecl = struct {
    name: []const u8,
    targets: []AnnotationTarget,
    uses: []QualifiedName,
    parameters: []AnnotationParameterDecl,
    generated_members: []GeneratedMember,
    span: Span,
};

pub const CapabilityDecl = struct {
    name: []const u8,
    generated_members: []GeneratedMember,
    span: Span,
};

pub const AnnotationTarget = enum {
    class,
    struct_decl,
    function,
    construct,
    field,
};

pub const AnnotationParameterDecl = struct {
    name: []const u8,
    type_expr: *TypeExpr,
    default_value: ?*Expr,
    span: Span,
};

pub const GeneratedMember = struct {
    overridable: bool,
    member: BodyMember,
    span: Span,
};

pub const FunctionDecl = struct {
    annotations: []const Annotation,
    is_override: bool = false,
    is_comptime: bool = false,
    is_async: bool = false,
    name: []const u8,
    params: []ParamDecl,
    return_type: ?*TypeExpr,
    body: ?Block,
    span: Span,
};

pub const FunctionSignature = struct {
    annotations: []const Annotation = &.{},
    name: []const u8,
    params: []ParamDecl,
    return_type: ?*TypeExpr,
    span: Span,
};

pub const TypeAliasDecl = struct {
    name: []const u8,
    target: *TypeExpr,
    span: Span,
};

// --- Macros -----------------------------------------------------------------
//
// `macro Name(p: expr) { expand { ... } }` is a declarative macro: a fixed template with
// fragment substitution, hygiene, and single-evaluation `expr` semantics. `comptime macro
// Name { kind { function|attribute|derive } appliesTo { ... } expand(...) -> Syntax { ... } }`
// is a procedural macro whose `expand` runs at compile time. Both are consumed and removed by
// the macro-expansion pass (see kira_build/src/macro_expand.zig) before semantic analysis, so
// `macro_decl` and macro-call nodes never reach HIR lowering.

pub const MacroKind = enum {
    declarative,
    proc_function,
    proc_attribute,
    proc_derive,
    // `kind { wrapper }`: the property-wrapper protocol macro. Annotating a struct with the
    // macro's name (`@PropertyWrapper struct State { ... }`) validates it and registers it as a
    // wrapper TEMPLATE (the struct itself is removed from the program — it may carry placeholder
    // types). A field annotated with a registered template's name (`@State var count: Int = 0`)
    // then summons the macro over the enclosing declaration with BOTH declarations bound:
    // `expand(target: Declaration, wrapper: Declaration)`; the output replaces the target.
    // On the validation invocation the macro receives (template, template) — `target.name ==
    // wrapper.name` discriminates the two paths.
    proc_wrapper,
};

// Fragment kind for a declarative macro parameter.
//   expr  - a single expression, captured call-by-value (evaluated exactly once).
//   place - an assignable lvalue path, substituted by reference (for swap-style macros).
pub const FragmentKind = enum {
    expr,
    place,
};

pub const MacroParam = struct {
    name: []const u8,
    kind: FragmentKind,
    span: Span,
};

// Declaration kinds an attribute/derive macro may legally apply to.
pub const MacroTargetKind = enum {
    struct_target,
    class_target,
    enum_target,
    // A construct-backed declaration form (`Widget Counter(...) { ... }`).
    form_target,
};

pub const MacroDecl = struct {
    annotations: []const Annotation = &.{},
    kind: MacroKind,
    name: []const u8,
    // Declarative macros: fragment parameters + the `expand { ... }` template block.
    params: []MacroParam = &.{},
    expand_block: ?Block = null,
    // Procedural macros: legal targets (attribute/derive only) + the `expand(...) -> Syntax`
    // function carrying the compile-time body.
    applies_to: []MacroTargetKind = &.{},
    expand_fn: ?FunctionDecl = null,
    // `trigger { field }`: this attribute macro auto-applies to a whole declaration whenever one
    // of the declaration's FIELDS carries an annotation matching the macro's name — the
    // property-wrapper shape (`@State var count: Int = 0` summons macro `State` over the form).
    trigger_field: bool = false,
    // `replace { true }`: the macro's output REPLACES the annotated declaration instead of being
    // appended alongside it. Required for rewriting macros (property wrappers).
    replace: bool = false,
    span: Span,
};

pub const ParamDecl = struct {
    annotations: []const Annotation,
    name: []const u8,
    type_expr: ?*TypeExpr,
    default_value: ?*Expr = null,
    span: Span,
};

pub const EnumDecl = struct {
    annotations: []const Annotation = &.{},
    name: []const u8,
    type_params: [][]const u8,
    variants: []EnumVariantDecl,
    // Set by the macro expander when `@Derive(Copy)` is present. It transports the
    // opt-in copyability assertion past annotation stripping down into semantics/mid-IR,
    // where the structural `Copy` classifier verifies every variant payload is copyable.
    derive_copy: bool = false,
    span: Span,
};

pub const EnumVariantDecl = struct {
    name: []const u8,
    associated_type: ?*TypeExpr,
    default_value: ?*Expr,
    span: Span,
};

pub const TypeDecl = struct {
    kind: TypeKind,
    annotations: []const Annotation,
    name: []const u8,
    parents: []QualifiedName,
    members: []BodyMember,
    // Set by the macro expander when `@Derive(Copy)` is present. It transports the
    // opt-in copyability assertion past annotation stripping down into semantics/mid-IR,
    // where the structural `Copy` classifier verifies every field is copyable.
    derive_copy: bool = false,
    span: Span,
};

pub const TypeKind = enum {
    class,
    struct_decl,
};

pub const ConstructDecl = struct {
    annotations: []const Annotation,
    is_comptime: bool = false,
    name: []const u8,
    parents: []QualifiedName,
    sections: []ConstructSection,
    // Direct, SwiftUI-style members declared at the construct body's top level, e.g.
    // `@Required let body: Widget`, `@Required function measure(...) -> Size`, or a default
    // computed member `let node: Node { body.node }`. These coexist with the older
    // section-based surface; an empty slice means the construct uses only sections.
    members: []BodyMember = &.{},
    span: Span,
};

pub const ConstructSection = struct {
    name: []const u8,
    kind: ConstructSectionKind,
    entries: []ConstructSectionEntry,
    span: Span,
};

pub const ConstructSectionKind = enum {
    annotations,
    modifiers,
    requires,
    lifecycle,
    builder,
    representation,
    properties,
    custom,
};

pub const ConstructSectionEntry = union(enum) {
    annotation_spec: AnnotationSpec,
    field_decl: FieldDecl,
    lifecycle_hook: LifecycleHook,
    function_signature: FunctionSignature,
    property_schema: PropertySchemaField,
    content_channel: ContentChannelSchema,
    content_directive: ContentDirective,
    content_projection: ContentProjection,
    named_rule: NamedRule,
};

// A content-composition directive on a construct's `content` section: `content sealed`,
// `content refine { ... }`, `content passthrough`, or `content project { ... }`.
pub const ContentDirective = struct {
    mode: ContentDirectiveMode,
    span: Span,
};

pub const ContentDirectiveMode = enum { sealed, refine, passthrough, project };

// A `content project { local as Parent.channel }` mapping: the declaration section named
// `local` fills `Parent`'s `channel`.
pub const ContentProjection = struct {
    local: []const u8,
    target_construct: QualifiedName,
    target_channel: []const u8,
    span: Span,
};

// A named content channel declared in a construct's `content { ... }` block, e.g.
// `head { accepts WebElement; count 0..1 }`. `accepts` constrains the element type a
// construct-backed declaration may place in the channel; `count` constrains how many.
pub const ContentChannelSchema = struct {
    name: []const u8,
    accepts: ?QualifiedName,
    count: ?CountRange,
    span: Span,
};

// An inclusive lower bound and optional upper bound, written `min..max` or `min..`.
// `0..` is {0, null}, `0..1` is {0, 1}, `1..` is {1, null}.
pub const CountRange = struct {
    min: u32,
    max: ?u32,
    span: Span,
};

// A typed slot in a construct's `properties { ... }` schema, e.g. `required path: String`
// or `uuid: UUID`. `required` declarations must be provided by every construct-backed
// declaration; non-required declarations are optional/defaultable.
pub const PropertySchemaField = struct {
    required: bool,
    name: []const u8,
    type_expr: ?*TypeExpr,
    default_value: ?*Expr,
    span: Span,
};

pub const AnnotationSpec = struct {
    name: QualifiedName,
    type_expr: ?*TypeExpr,
    default_value: ?*Expr,
    span: Span,
};

pub const NamedRule = struct {
    name: QualifiedName,
    args: []RuleArg,
    type_expr: ?*TypeExpr,
    value: ?*Expr,
    block: ?Block,
    span: Span,
};

pub const RuleArg = struct {
    label: ?[]const u8,
    value: ?*Expr,
    span: Span,
};

pub const ConstructFormDecl = struct {
    annotations: []const Annotation,
    construct_name: QualifiedName,
    name: []const u8,
    params: []ParamDecl,
    body: ConstructBody,
    span: Span,
};

pub const ConstructBody = struct {
    members: []BodyMember,
    span: Span,
};

// A `FailTest Name { backends {...} source {...} expect {...} }` declaration: an
// expected-compile-outcome test written in pure Kira. Its `source` is QUOTED —
// the parser captures the block's raw text and the enclosing package's semantic
// analysis never sees its contents (ill-formed code must not poison the suite).
// The `kira test` runner compiles the captured text as a synthetic single-file
// package, once per declared backend, and passes iff the compile outcome matches
// the `expect` block. See packages/kira_main/src/developer_failtest.zig.
pub const FailTestSource = union(enum) {
    /// Raw source text captured verbatim from a `source { ... }` block.
    block: []const u8,
    /// The decoded value of a `source = "..."` string literal (raw-string tier,
    /// for sources that must NOT even tokenize/brace-balance — parser diagnostics).
    string: []const u8,
};

pub const FailTestDecl = struct {
    annotations: []const Annotation,
    name: []const u8,
    /// Declared backends (lowercase idents from `backends { ... }`), a subset of
    /// {vm, llvm, hybrid}. Empty means the omitted-block default: vm only.
    backends: []const []const u8,
    /// The quoted source to compile, or null when the `source` section is missing.
    source: ?FailTestSource,
    /// Raw text of the `expect { ... }` block, for textual extraction of the
    /// expected diagnostic code and Ok/Error polarity. Null when missing.
    expect_text: ?[]const u8,
    span: Span,
};

pub const BodyMember = union(enum) {
    field_decl: FieldDecl,
    function_decl: FunctionDecl,
    content_section: ContentSection,
    properties_section: DeclPropertiesSection,
    lifecycle_hook: LifecycleHook,
    named_rule: NamedRule,
};

// A construct-backed declaration supplies its construct's declared properties through a
// section: `Route Home { properties { path: "/" } }`. Each entry binds a schema property
// name to a value expression. There is no constructor-style `Route Home(path: "/")` form.
pub const DeclPropertiesSection = struct {
    entries: []DeclPropertyEntry,
    span: Span,
};

pub const DeclPropertyEntry = struct {
    name: []const u8,
    value: *Expr,
    span: Span,
};

pub const FieldDecl = struct {
    annotations: []const Annotation,
    is_override: bool = false,
    storage: FieldStorage,
    name: []const u8,
    type_expr: ?*TypeExpr,
    value: ?*Expr,
    // A block-bodied computed member, e.g. `let node: Node { body.node }`. When present the
    // field is a computed default/override rather than stored state, and `value` is null.
    body: ?Block = null,
    span: Span,
};

pub const FieldStorage = enum {
    immutable,
    mutable,
};

pub const ContentSection = struct {
    annotations: []const Annotation,
    builder: BuilderBlock,
    span: Span,
};

pub const LifecycleHook = struct {
    name: []const u8,
    args: []RuleArg,
    body: Block,
    span: Span,
};

pub const Block = exprs.Block;
pub const Statement = exprs.Statement;
pub const AttemptStatement = exprs.AttemptStatement;
pub const HandleCase = exprs.HandleCase;
pub const LetStatement = exprs.LetStatement;
pub const ExprStatement = exprs.ExprStatement;
pub const AssignStatement = exprs.AssignStatement;
pub const ReturnStatement = exprs.ReturnStatement;
pub const IfStatement = exprs.IfStatement;
pub const ForStatement = exprs.ForStatement;
pub const WhileStatement = exprs.WhileStatement;
pub const BreakStatement = exprs.BreakStatement;
pub const ContinueStatement = exprs.ContinueStatement;
pub const MatchStatement = exprs.MatchStatement;
pub const MatchArm = exprs.MatchArm;
pub const MatchPattern = exprs.MatchPattern;
pub const SwitchStatement = exprs.SwitchStatement;
pub const SwitchCase = exprs.SwitchCase;
pub const BuilderBlock = exprs.BuilderBlock;
pub const BuilderItem = exprs.BuilderItem;
pub const BuilderExprItem = exprs.BuilderExprItem;
pub const BuilderFieldOverrideItem = exprs.BuilderFieldOverrideItem;
pub const BuilderIfItem = exprs.BuilderIfItem;
pub const BuilderForItem = exprs.BuilderForItem;
pub const BuilderSwitchItem = exprs.BuilderSwitchItem;
pub const BuilderSwitchCase = exprs.BuilderSwitchCase;
pub const Expr = exprs.Expr;
pub const QuoteExpr = exprs.QuoteExpr;
pub const QuotePart = exprs.QuotePart;
pub const TryExpr = exprs.TryExpr;
pub const IntegerLiteral = exprs.IntegerLiteral;
pub const FloatLiteral = exprs.FloatLiteral;
pub const StringLiteral = exprs.StringLiteral;
pub const BoolLiteral = exprs.BoolLiteral;
pub const IdentifierExpr = exprs.IdentifierExpr;
pub const ArrayExpr = exprs.ArrayExpr;
pub const BuilderArrayExpr = exprs.BuilderArrayExpr;
pub const StructLiteralExpr = exprs.StructLiteralExpr;
pub const StructLiteralField = exprs.StructLiteralField;
pub const NativeStateExpr = exprs.NativeStateExpr;
pub const NativeUserDataExpr = exprs.NativeUserDataExpr;
pub const NativeRecoverExpr = exprs.NativeRecoverExpr;
pub const NativeStateFreeExpr = exprs.NativeStateFreeExpr;
pub const OwnershipExpr = exprs.OwnershipExpr;
pub const OwnershipExprOp = exprs.OwnershipExprOp;
pub const UnaryExpr = exprs.UnaryExpr;
pub const BinaryExpr = exprs.BinaryExpr;
pub const ConditionalExpr = exprs.ConditionalExpr;
pub const MemberExpr = exprs.MemberExpr;
pub const IndexExpr = exprs.IndexExpr;
pub const CallExpr = exprs.CallExpr;
pub const CallArg = exprs.CallArg;
pub const BinaryOp = exprs.BinaryOp;
pub const UnaryOp = exprs.UnaryOp;
pub const TypeExpr = exprs.TypeExpr;
pub const OwnershipMode = exprs.OwnershipMode;
pub const OwnershipTypeExpr = exprs.OwnershipTypeExpr;
pub const AnyTypeExpr = exprs.AnyTypeExpr;
pub const ArrayTypeExpr = exprs.ArrayTypeExpr;
pub const FunctionTypeExpr = exprs.FunctionTypeExpr;
pub const GenericTypeExpr = exprs.GenericTypeExpr;
pub const CallbackBlock = exprs.CallbackBlock;
pub const CallbackParam = exprs.CallbackParam;
pub const dumpProgram = @import("ast_dump.zig").dumpProgram;
