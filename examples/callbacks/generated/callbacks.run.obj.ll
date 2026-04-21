; ModuleID = "main"
source_filename = "main"
target triple = "x86_64-pc-windows-msvc"

%t.CounterState = type { i64, i64 }

%kira.string = type { ptr, i64 }

%kira.bridge.value = type { i8, [7 x i8], i64, i64 }

@kira_bool_true_data = private unnamed_addr constant [5 x i8] c"true\00"
@kira_bool_true = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([5 x i8], ptr @kira_bool_true_data, i64 0, i64 0), i64 4 }
@kira_bool_false_data = private unnamed_addr constant [6 x i8] c"false\00"
@kira_bool_false = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([6 x i8], ptr @kira_bool_false_data, i64 0, i64 0), i64 5 }

declare void @"kira_native_print_i64"(i64)
declare void @"kira_native_print_f64"(double)
declare void @"kira_native_print_string"(ptr, i64)
declare ptr @"kira_array_alloc"(i64)
declare i64 @"kira_array_len"(ptr)
declare void @"kira_array_store"(ptr, i64, ptr)
declare void @"kira_array_load"(ptr, i64, ptr)
declare ptr @"kira_native_state_alloc"(i64, i64)
declare ptr @"kira_native_state_payload"(ptr)
declare ptr @"kira_native_state_recover"(ptr, i64)
declare ptr @malloc(i64)
declare void @"kira_hybrid_call_runtime"(i32, ptr, i32, ptr)
declare i64 @"kira_invoke_callback"(ptr, ptr, i64)



define i64 @"kira_native_impl_1"(i64 %arg0, i64 %arg1) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  store i64 %arg0, ptr %local0
  store i64 %arg1, ptr %local1
  %r0 = ptrtoint ptr @"kira_native_impl_2" to i64
  %r1 = load i64, ptr %local0
  %r2 = load i64, ptr %local1
  %call.arg.3.0 = inttoptr i64 %r0 to ptr
  %call.arg.3.1 = inttoptr i64 %r1 to ptr
  %r3 = call i64 @"kira_invoke_callback"(ptr %call.arg.3.0, ptr %call.arg.3.1, i64 %r2)
  ret i64 %r3
}

define i64 @"kira_native_impl_2"(i64 %arg0, i64 %arg1) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  %local2 = alloca i64
  store i64 %arg0, ptr %local0
  store i64 %arg1, ptr %local1
  %r0 = load i64, ptr %local1
  %native.recover.state.1 = inttoptr i64 %r0 to ptr
  %native.recover.payload.1 = call ptr @"kira_native_state_recover"(ptr %native.recover.state.1, i64 563672744983663220)
  %r1 = ptrtoint ptr %native.recover.payload.1 to i64
  store i64 %r1, ptr %local2
  %r2 = load i64, ptr %local2
  %native.state.get.ptr.3 = inttoptr i64 %r2 to ptr
  %native.state.get.slot.3 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.3, i64 0
  %native.state.get.val.0 = load %kira.bridge.value, ptr %native.state.get.slot.3
  %r3 = extractvalue %kira.bridge.value %native.state.get.val.0, 2
  %r4 = add i64 0, 1
  %r5 = add i64 %r3, %r4
  %r6 = load i64, ptr %local2
  %native.state.set.ptr.5 = inttoptr i64 %r6 to ptr
  %native.state.set.slot.5 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.5, i64 0
  %native.state.set.pack.1.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.set.pack.1 = insertvalue %kira.bridge.value %native.state.set.pack.1.0, i64 %r5, 2
  store %kira.bridge.value %native.state.set.pack.1, ptr %native.state.set.slot.5
  %r7 = load i64, ptr %local2
  %native.state.get.ptr.8 = inttoptr i64 %r7 to ptr
  %native.state.get.slot.8 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.8, i64 1
  %native.state.get.val.2 = load %kira.bridge.value, ptr %native.state.get.slot.8
  %r8 = extractvalue %kira.bridge.value %native.state.get.val.2, 2
  %r9 = load i64, ptr %local0
  %r10 = add i64 %r8, %r9
  %r11 = load i64, ptr %local2
  %native.state.set.ptr.10 = inttoptr i64 %r11 to ptr
  %native.state.set.slot.10 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.10, i64 1
  %native.state.set.pack.3.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.set.pack.3 = insertvalue %kira.bridge.value %native.state.set.pack.3.0, i64 %r10, 2
  store %kira.bridge.value %native.state.set.pack.3, ptr %native.state.set.slot.10
  %r12 = load i64, ptr %local0
  %r13 = load i64, ptr %local2
  %native.state.get.ptr.14 = inttoptr i64 %r13 to ptr
  %native.state.get.slot.14 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.14, i64 0
  %native.state.get.val.4 = load %kira.bridge.value, ptr %native.state.get.slot.14
  %r14 = extractvalue %kira.bridge.value %native.state.get.val.4, 2
  %r15 = add i64 %r12, %r14
  ret i64 %r15
}

define dllexport void @"kira_native_fn_1"(ptr %args, i32 %arg_count, ptr %out_result) {
entry:
  %bridge.slot.0 = getelementptr inbounds %kira.bridge.value, ptr %args, i64 0
  %bridge.load.0 = load %kira.bridge.value, ptr %bridge.slot.0
  %bridge.word0.0 = extractvalue %kira.bridge.value %bridge.load.0, 2
  %bridge.slot.1 = getelementptr inbounds %kira.bridge.value, ptr %args, i64 1
  %bridge.load.1 = load %kira.bridge.value, ptr %bridge.slot.1
  %bridge.word0.1 = extractvalue %kira.bridge.value %bridge.load.1, 2
  %bridge.call = call i64 @"kira_native_impl_1"(i64 %bridge.word0.0, i64 %bridge.word0.1)
  %bridge.out.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %bridge.out.1 = insertvalue %kira.bridge.value %bridge.out.0, i64 %bridge.call, 2
  store %kira.bridge.value %bridge.out.1, ptr %out_result
  ret void
}

define dllexport void @"kira_native_fn_2"(ptr %args, i32 %arg_count, ptr %out_result) {
entry:
  %bridge.slot.0 = getelementptr inbounds %kira.bridge.value, ptr %args, i64 0
  %bridge.load.0 = load %kira.bridge.value, ptr %bridge.slot.0
  %bridge.word0.0 = extractvalue %kira.bridge.value %bridge.load.0, 2
  %bridge.slot.1 = getelementptr inbounds %kira.bridge.value, ptr %args, i64 1
  %bridge.load.1 = load %kira.bridge.value, ptr %bridge.slot.1
  %bridge.word0.1 = extractvalue %kira.bridge.value %bridge.load.1, 2
  %bridge.call = call i64 @"kira_native_impl_2"(i64 %bridge.word0.0, i64 %bridge.word0.1)
  %bridge.out.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %bridge.out.1 = insertvalue %kira.bridge.value %bridge.out.0, i64 %bridge.call, 2
  store %kira.bridge.value %bridge.out.1, ptr %out_result
  ret void
}

