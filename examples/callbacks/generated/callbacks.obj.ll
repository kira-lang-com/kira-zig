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
declare i64 @"kira_invoke_callback"(ptr, ptr, i64)



@kira_str_0_data = private unnamed_addr constant [10 x i8] c"callbacks\00"

@kira_str_0 = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([10 x i8], ptr @kira_str_0_data, i64 0, i64 0), i64 9 }


define void @"kira_fn_0_main"() {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  %local2 = alloca i64
  %r0 = load %kira.string, ptr @kira_str_0
  %str.ptr.0 = extractvalue %kira.string %r0, 0
  %str.len.0 = extractvalue %kira.string %r0, 1
  call void @"kira_native_print_string"(ptr %str.ptr.0, i64 %str.len.0)
  %alloc.size.ptr.1 = getelementptr inbounds %t.CounterState, ptr null, i32 1
  %alloc.size.1 = ptrtoint ptr %alloc.size.ptr.1 to i64
  %alloc.ptr.1 = call ptr @malloc(i64 %alloc.size.1)
  store %t.CounterState zeroinitializer, ptr %alloc.ptr.1
  %r1 = ptrtoint ptr %alloc.ptr.1 to i64
  %r2 = add i64 0, 0
  %field.base.3 = inttoptr i64 %r1 to ptr
  %field.ptr.3 = getelementptr inbounds %t.CounterState, ptr %field.base.3, i32 0, i32 0
  %r3 = ptrtoint ptr %field.ptr.3 to i64
  %store.ptr.2 = inttoptr i64 %r3 to ptr
  store i64 %r2, ptr %store.ptr.2
  %r4 = add i64 0, 0
  %field.base.5 = inttoptr i64 %r1 to ptr
  %field.ptr.5 = getelementptr inbounds %t.CounterState, ptr %field.base.5, i32 0, i32 1
  %r5 = ptrtoint ptr %field.ptr.5 to i64
  %store.ptr.4 = inttoptr i64 %r5 to ptr
  store i64 %r4, ptr %store.ptr.4
  %native.state.size.ptr.6 = getelementptr inbounds [2 x %kira.bridge.value], ptr null, i32 1
  %native.state.size.6 = ptrtoint ptr %native.state.size.ptr.6 to i64
  %native.state.box.6 = call ptr @"kira_native_state_alloc"(i64 563672744983663220, i64 %native.state.size.6)
  %native.state.payload.6 = call ptr @"kira_native_state_payload"(ptr %native.state.box.6)
  %native.state.src.6 = inttoptr i64 %r1 to ptr
  %native.state.src.field.ptr.6.0 = getelementptr inbounds %t.CounterState, ptr %native.state.src.6, i32 0, i32 0
  %native.state.slot.ptr.6.0 = getelementptr inbounds %kira.bridge.value, ptr %native.state.payload.6, i64 0
  %native.state.pack.6.0.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.load.int.6.0 = load i64, ptr %native.state.src.field.ptr.6.0
  %native.state.pack.6.0 = insertvalue %kira.bridge.value %native.state.pack.6.0.0, i64 %native.state.load.int.6.0, 2
  store %kira.bridge.value %native.state.pack.6.0, ptr %native.state.slot.ptr.6.0
  %native.state.src.field.ptr.6.1 = getelementptr inbounds %t.CounterState, ptr %native.state.src.6, i32 0, i32 1
  %native.state.slot.ptr.6.1 = getelementptr inbounds %kira.bridge.value, ptr %native.state.payload.6, i64 1
  %native.state.pack.6.1.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.load.int.6.1 = load i64, ptr %native.state.src.field.ptr.6.1
  %native.state.pack.6.1 = insertvalue %kira.bridge.value %native.state.pack.6.1.0, i64 %native.state.load.int.6.1, 2
  store %kira.bridge.value %native.state.pack.6.1, ptr %native.state.slot.ptr.6.1
  %r6 = ptrtoint ptr %native.state.box.6 to i64
  store i64 %r6, ptr %local0
  %r7 = load i64, ptr %local0
  store i64 %r7, ptr %local1
  %r8 = load i64, ptr %local1
  %r9 = add i64 0, 5
  %r10 = call i64 @"kira_fn_1_run_native"(i64 %r8, i64 %r9)
  call void @"kira_native_print_i64"(i64 %r10)
  %r11 = load i64, ptr %local1
  %r12 = add i64 0, 7
  %r13 = call i64 @"kira_fn_1_run_native"(i64 %r11, i64 %r12)
  call void @"kira_native_print_i64"(i64 %r13)
  %r14 = load i64, ptr %local1
  %native.recover.state.15 = inttoptr i64 %r14 to ptr
  %native.recover.payload.15 = call ptr @"kira_native_state_recover"(ptr %native.recover.state.15, i64 563672744983663220)
  %r15 = ptrtoint ptr %native.recover.payload.15 to i64
  store i64 %r15, ptr %local2
  %r16 = load i64, ptr %local2
  %native.state.get.ptr.17 = inttoptr i64 %r16 to ptr
  %native.state.get.slot.17 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.17, i64 0
  %native.state.get.val.1 = load %kira.bridge.value, ptr %native.state.get.slot.17
  %r17 = extractvalue %kira.bridge.value %native.state.get.val.1, 2
  call void @"kira_native_print_i64"(i64 %r17)
  %r18 = load i64, ptr %local2
  %native.state.get.ptr.19 = inttoptr i64 %r18 to ptr
  %native.state.get.slot.19 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.19, i64 1
  %native.state.get.val.2 = load %kira.bridge.value, ptr %native.state.get.slot.19
  %r19 = extractvalue %kira.bridge.value %native.state.get.val.2, 2
  call void @"kira_native_print_i64"(i64 %r19)
  ret void
}

define i64 @"kira_fn_1_run_native"(i64 %arg0, i64 %arg1) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  store i64 %arg0, ptr %local0
  store i64 %arg1, ptr %local1
  %r0 = ptrtoint ptr @"kira_fn_2_add_and_track" to i64
  %r1 = load i64, ptr %local0
  %r2 = load i64, ptr %local1
  %call.arg.3.0 = inttoptr i64 %r0 to ptr
  %call.arg.3.1 = inttoptr i64 %r1 to ptr
  %r3 = call i64 @"kira_invoke_callback"(ptr %call.arg.3.0, ptr %call.arg.3.1, i64 %r2)
  ret i64 %r3
}

define i64 @"kira_fn_2_add_and_track"(i64 %arg0, i64 %arg1) {
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

define i32 @main() {
entry:
  call void @"kira_fn_0_main"()
  ret i32 0
}

