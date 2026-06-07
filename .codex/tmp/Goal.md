Complete the real Kira UI + UI Foundation + Kira Graphics input/render integration.

Goal
Make the intended Kira UI stack real and visible on screen:

Kira UI -> UI Foundation -> Kira Graphics

Kira Graphics must expose real screen/input primitives. UI Foundation must consume those primitives and produce real retained-tree/layout/render behavior. Kira UI must expose the intended declarative construct-backed API. The compiler must support the updated general-purpose construct system, property wrappers, modifier chaining, overloads, extension functions, unlabeled _ parameters, and normal constructor/component call syntax required by Kira UI.

Additionally, restore the full Rust-style memory-switch implementation and integrate it across the compiler, runtime, UI Foundation, Kira UI, and Kira Graphics layers. The memory model must support explicit ownership, borrowing, move semantics, lifetime validation, capture analysis, and backend-consistent lowering. Re-enable all previously intended memory-switch paths rather than partial or stub implementations.

Memory requirements:

* full Rust-style memory-switch behavior restored
* ownership and borrow validation integrated with construct lowering
* ownership and borrow validation integrated with property-wrapper lowering
* closure capture ownership validated before execution
* retained-tree nodes participate in ownership/lifetime analysis
* callback storage participates in ownership/lifetime analysis
* UI state storage participates in ownership/lifetime analysis
* no hidden host-managed ownership escapes
* no backend-specific ownership bypasses
* deterministic destruction behavior where applicable
* move-only and non-copy types validated consistently
* borrow conflicts diagnosed with precise source locations
* lifetime violations diagnosed before backend execution
* VM, LLVM/native, hybrid, and WASM paths share equivalent ownership semantics or emit explicit diagnostics

Memory validation and leak verification requirements:

* add dedicated ownership-analysis tests
* add dedicated borrow-checking tests
* add move-semantics tests
* add closure-capture ownership tests
* add property-wrapper ownership tests
* add retained-tree lifetime tests
* add callback lifetime tests
* add UI state lifetime tests
* add backend parity ownership tests
* add stress tests for widget creation/destruction
* add stress tests for retained-tree rebuild/update cycles
* add stress tests for callback registration/removal
* add stress tests for focus routing and input dispatch
* add stress tests for scrolling and viewport updates
* add allocator accounting verification where supported
* add leak-detection verification for compiler tests
* add leak-detection verification for runtime tests
* add leak-detection verification for UI Foundation tests
* add leak-detection verification for Kira UI examples
* fail validation if ownership violations, leaks, double-frees, use-after-free conditions, dangling references, invalid borrows, or allocator mismatches are detected

Test harness requirements:

* restore and expand the complete validation harness
* provide compiler feature harness coverage
* provide runtime harness coverage
* provide VM harness coverage
* provide LLVM/native harness coverage
* provide hybrid harness coverage
* provide WASM harness coverage where applicable
* provide UI Foundation integration harness coverage
* provide Kira UI integration harness coverage
* provide Kira Graphics integration harness coverage
* provide end-to-end interaction harness coverage
* provide screenshot validation harness support
* provide memory-accounting harness support
* provide leak-verification harness support
* provide ownership-diagnostic golden tests
* provide construct/property-wrapper/modifier golden tests
* provide backend parity comparison tests
* provide reproducible pass/fail reporting with exact counts

Do not ship placeholder UI, host-rendered content, smoke markers, public workaround aliases, numeric-ID demo APIs, or VM-only behavior.

Context
Kira UI is the high-level declarative UI package built on top of UI Foundation.

UI Foundation renders through Kira Graphics.

Kira UI imports UI Foundation only. Kira UI must not import Kira Graphics directly.

Kira Web is separate and depends only on Foundation/browser APIs. Do not merge Kira UI into Kira Web.

The current free-function/demo style such as UI.padding, UI.Button, numeric IDs, or bridge-only calls is not the target public API. Fix the compiler/module/export/construct issues instead of adding workaround aliases.

Target syntax: general construct system
construct is used only at declaration sites. Usage is a normal call.

construct Widget {
    content: Content<Widget>
}
Widget Greeting(name: String) {
    content {
        Text("Hello, \(name)")
    }
}
Widget App() {
    content {
        Greeting("Kira")
    }
}

This must be invalid:

Widget BadApp() {
    content {
        construct Greeting("Kira")
    }
}

Expected diagnostic shape:

error[KSEMxxx]: `construct` is only valid at declaration sites
help: call the widget normally: `Greeting("Kira")`

Construct families must be general-purpose, not hardcoded only for UI widgets.

construct Command {
    requires run: () -> Int
}
Command BuildProject(path: String) {
    run {
        build(path)
    }
}
let command = BuildProject("examples/hello")
let exitCode = command.run()

Route-like construct example:

construct Route {
    requires path: String
    content: Content<Widget>
}
Route HomeRoute() {
    path "/"
    content {
        HomeScreen()
    }
}

The compiler must validate construct families, required sections, typed sections, typed content, duplicate sections, invalid sections, lifecycle/lowering rules, annotations where present, and normal call-site usage.

Required invalid construct cases:

* unknown construct family
* construct used at call site
* missing required section
* duplicate section
* invalid section name
* section type mismatch
* invalid construct content type
* construct usage before export/import resolution succeeds

Target syntax: property wrappers
Implement general property-wrapper support required by Kira UI.

Target declaration shape:

@PropertyWrapper
struct State<Value> {
    var wrappedValue: Value
    var projectedValue: Binding<Value>
}
@PropertyWrapper
struct Binding<Value> {
    var wrappedValue: Value
}
@PropertyWrapper
struct Environment<Value> {
    let keyPath: EnvironmentKeyPath<Value>
    var wrappedValue: Value
}

State example:

Widget CounterLabel() {
    @State var count: Int = 0
    content {
        VStack(spacing: 8) {
            Text("Count: \(count)")
            Button("+") {
                count += 1
            }
        }
    }
}

Binding propagation:

Widget TodoEditor(title: Binding<String>, isDone: Binding<Bool>) {
    content {
        VStack(spacing: 8) {
            TextField("Title", text: title)
            Toggle("Done", isOn: isDone)
        }
    }
}
Widget TodoScreen() {
    @State var title: String = "Fix Kira UI"
    @State var isDone: Bool = false
    content {
        TodoEditor(title: $title, isDone: $isDone)
        Text(isDone ? "Complete" : "In progress")
    }
}

Environment example:

Widget ThemedLabel(text: String) {
    @Environment(\.colorScheme) var colorScheme: ColorScheme
    @Environment(\.fontScale) var fontScale: Float
    content {
        Text(text)
            .fontSize(14 * fontScale)
            .foregroundColor(colorScheme == .dark ? .white : .black)
    }
}

Required property-wrapper behavior:

* reading name reads wrappedValue
* assigning name = value writes wrappedValue when the wrapper allows mutation
* $name returns projectedValue
* @State creates widget-owned state
* @Binding represents externally owned mutable state
* @Environment reads from environment and is not directly assignable
* wrappers participate in ownership/lifetime analysis
* wrapper storage must not be faked with host-side global state
* wrapper behavior must check/lower consistently for VM, LLVM/native, and hybrid where applicable

Required invalid wrapper cases:

* invalid @PropertyWrapper declaration
* wrapper used in invalid position
* $value on a non-wrapper value
* assignment to read-only environment value
* unsupported wrapper lowering for a backend
* invalid wrapper ownership/capture behavior
* binding parameter reassigned as a binding instead of mutating the wrapped value

Target syntax: Kira UI public API
Kira UI must support declarative construct-backed syntax like this:

import KiraUI
Widget InteractiveKitchenSink() {
    @State var count: Int = 0
    @State var name: String = ""
    @State var showDetails: Bool = true
    content {
        VStack(spacing: 16) {
            Text("Kira UI Kitchen Sink")
                .font(.title)
                .padding(.bottom, 8)
            Text("Count: \(count)")
                .font(.body)
            HStack(spacing: 8) {
                Button("−") {
                    count -= 1
                }
                Button("+") {
                    count += 1
                }
            }
            TextField("Your name", text: $name)
            Toggle("Show details", isOn: $showDetails)
            if showDetails {
                GreetingCard(name: name, count: count)
                    .padding(12)
                    .background(.regularMaterial)
                    .cornerRadius(8)
            }
            ScrollView {
                VStack(spacing: 4) {
                    Text("Row 1")
                    Text("Row 2")
                    Text("Row 3")
                    Text("Row 4")
                    Text("Row 5")
                    Text("Row 6")
                    Text("Row 7")
                    Text("Row 8")
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
Widget GreetingCard(name: String, count: Int) {
    content {
        VStack(spacing: 6) {
            Text("Hello \(name)")
            Text("You clicked \(count) times")
        }
    }
}

Required Kira UI surface:

* Text
* Button
* TextField
* Toggle
* VStack
* HStack
* ScrollView
* ordered modifiers
* callback closures
* state/binding/environment-backed widgets
* real examples under ../kira_ui
* no workaround aliases such as WidgetText, WidgetButton, or WidgetPadding

Parameter and overload syntax
Support unlabeled _ parameters and labeled parameters for natural UI APIs.

Widget Button(_ title: String, action: () -> Void) {
    content {
        // lowers to UI Foundation button node
    }
}
Button("Save") {
    save()
}
VStack(spacing: 12) {
    Text("A")
    Text("B")
}
HStack(alignment: .center, spacing: 8) {
    Button("Cancel") { cancel() }
    Button("Save") { save() }
}

Modifier syntax
Modifiers must be extension functions where appropriate, preserve order, and lower through UI Foundation.

extension Widget {
    function padding(_ amount: Float) -> Widget
    function padding(_ edges: Edge.Set, _ amount: Float) -> Widget
    function frame(width: Float, height: Float) -> Widget
    function frame(maxWidth: Float, maxHeight: Float) -> Widget
    function cornerRadius(_ radius: Float) -> Widget
}

Required examples:

Text("A").padding(8)
Text("B").padding(.horizontal, 16)
Text("C").frame(width: 120, height: 44)
Text("D").frame(maxWidth: .infinity, maxHeight: .infinity)
Text("Hello")
    .font(.title)
    .foregroundColor(.primary)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .cornerRadius(10)

Do not sort, deduplicate, ignore, or reorder modifiers. Ordered modifier behavior must be observable in UI Foundation output.

Callbacks and ownership
Callbacks must use the compiler’s explicit closure-capture ownership metadata. Do not rely on VM refcounting, host closure retention, or backend-specific capture behavior.

Valid Copy capture:

Widget CopyCaptureExample() {
    let step: Int = 2
    @State var count: Int = 0
    content {
        Button("Add") {
            count += step
        }
    }
}

Non-Copy captures must either be represented safely by the ownership model or rejected before backend execution with a precise diagnostic.

Widget NonCopyCaptureExample() {
    let items = ["A", "B", "C"]
    content {
        Button("Use items") {
            print(items[0])
        }
    }
}

Kira Graphics input/screen layer
Implement or repair the real Kira Graphics input and screen primitives needed by UI Foundation.

Required primitives:

* viewport size
* scale factor
* pointer position
* pointer down/up/move
* touch input where supported
* hover where supported
* scroll/wheel input
* keyboard key down/up
* text input/composition where available
* focus/active target routing support
* event ordering/timestamps if needed by the existing architecture

Kira Graphics exposes raw platform input and screen state. UI Foundation interprets it into UI concepts. Kira UI exposes the high-level declarative API.

UI Foundation
Fix UI Foundation so it can host real Kira UI output.

Required:

* retained tree behavior
* rebuild/update flow
* ordered modifier application
* callback routing
* layout data flow
* pointer/touch routing
* keyboard/text input routing
* focus model where needed
* scroll input path
* screen/viewport state
* integration with Kira Graphics for real draw submission
* no host placeholder rendering

On-screen validation
This task is not complete unless the result is tested visibly on screen.

Required evidence:

* launch the real Kira UI/UI Foundation sample through the intended runner
* capture screenshots of the running app
* screenshots must show Kira-generated UI content, not host placeholders
* interact with the app using real input:
    * click/tap + and verify count changes visibly
    * click/tap − and verify count changes visibly
    * type into TextField and verify greeting text changes visibly
    * toggle showDetails and verify visible UI changes
    * scroll the scroll view and verify viewport content changes when supported
    * verify focus/text input behavior where supported
* render success may be emitted only after real Kira-owned runtime/UI/layout/render-command/graphics work completes

Do not treat these as success:

* process launch
* install success
* window creation
* surface creation
* UI tree creation
* layout completion alone
* host-rendered placeholder content
* hardcoded success markers
* AppKit/UIKit/SwiftUI placeholder rendering
* JS/DOM placeholder rendering
* screenshots that do not prove Kira-generated visible content

Backend and compiler parity
The language/compiler work must preserve VM, LLVM/native, hybrid, and portable WASM behavior where applicable.

Required:

* VM behavior implemented or explicitly rejected with tested diagnostics
* LLVM/native behavior implemented or explicitly rejected with tested diagnostics
* hybrid behavior covered when relevant
* WASM behavior handled or explicitly rejected when the feature is portable
* no VM-only construct/property-wrapper behavior
* no backend-specific ownership loopholes
* no textual LLVM writer
* no Python

Tests
Add real tests, not smoke-only tests.

Required coverage:

* construct family declaration
* normal construct call-site usage
* invalid construct call-site usage
* required construct sections
* invalid/missing/duplicate construct sections
* typed Content<Widget>
* general-purpose non-UI construct family
* property-wrapper declarations
* @State
* @Binding
* @Environment
* $ projection
* invalid $ projection
* environment assignment rejection
* extension functions
* overload resolution
* unlabeled _ parameters
* ordered modifier chains
* unknown modifier diagnostic
* modifier overload ambiguity diagnostic
* Kira UI module/export resolution
* Kira UI importing UI Foundation but not Kira Graphics
* retained tree rebuild/update
* callback routing
* pointer/click input
* keyboard/text input
* scroll input where supported
* visible state update from interaction
* VM/LLVM/hybrid parity for compiler/language features
* check/run examples for ../kira_ui
* check/run examples for ../ui-foundation
* ownership analysis
* borrow checking
* move semantics
* lifetime validation
* closure capture ownership
* retained-tree destruction
* callback cleanup
* allocator accounting
* leak detection
* memory-switch parity across backends

Validation gates
Run the relevant repo commands and keep going until failures are fixed or the blocker is genuinely external.

Required:

* zig build
* zig build test
* zig build verify-real-runtime
* zig build verify-memory
* zig build verify-leaks
* zig build run -- check ../kira_ui
* zig build run -- check ../ui-foundation
* targeted construct/property-wrapper/modifier tests
* targeted ownership and borrow-check tests
* targeted memory-switch tests
* targeted Kira UI examples
* targeted UI Foundation examples
* VM/LLVM/hybrid coverage for compiler features
* allocator-accounting verification
* leak-verification runs
* on-screen runner validation with screenshots
* input validation proving click/tap, keyboard/text, toggle, and scroll/hover where supported

If signing, simulator availability, physical hardware, graphics device access, or platform support blocks a specific on-screen path, prove all repo-local pieces first, run the closest available desktop/simulator path, and report the exact external blocker. Do not stop before exhausting repo-local implementation and validation.

Done when
The task is complete only when:

* Kira Graphics exposes real input/screen primitives needed by UI Foundation
* UI Foundation consumes Kira Graphics input and renders real Kira-owned UI
* Kira UI exposes the intended construct-backed declarative API
* property wrappers work for @State, @Binding, @Environment, and $ projection
* the updated construct system works for general-purpose constructs and Kira UI widgets
* construct is declaration-site only; usage is normal calls
* modifier chains lower and execute in order
* callbacks and input update visible Kira-owned state on screen
* full Rust-style memory-switch behavior is restored
* ownership, borrowing, moves, and lifetimes are validated consistently
* memory leak verification passes
* allocator accounting verification passes
* no public workaround aliases were added
* Kira UI imports UI Foundation only
* VM/LLVM/hybrid/WASM behavior is implemented or explicitly diagnosed where relevant
* screenshots prove real Kira-generated UI content
* interaction tests prove real input handling
* all required validation commands have exact results
* remaining limitations, if any, are truly external and not repo-local unfinished work

Final report
Include:

* files changed
* compiler features implemented
* construct-system behavior implemented
* property-wrapper behavior implemented
* ownership/borrowing features implemented
* memory-switch behavior implemented
* memory verification and leak-check results
* test harness additions and coverage
* Kira Graphics input changes
* UI Foundation changes
* Kira UI public API changes

