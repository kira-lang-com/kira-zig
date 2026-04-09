; ModuleID = "main"
source_filename = "main"
target triple = "x86_64-pc-windows-msvc"

%kira.string = type { ptr, i64 }

%kira.bridge.value = type { i8, [7 x i8], i64, i64 }

declare void @"kira_native_print_i64"(i64)
declare void @"kira_native_print_string"(ptr, i64)
declare void @"kira_hybrid_call_runtime"(i32, ptr, i32, ptr)


@kira_str_0_data = private unnamed_addr constant [12 x i8] c"native main\00"

@kira_str_0 = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([12 x i8], ptr @kira_str_0_data, i64 0, i64 0), i64 11 }

@kira_str_1_data = private unnamed_addr constant [14 x i8] c"native helper\00"

@kira_str_1 = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([14 x i8], ptr @kira_str_1_data, i64 0, i64 0), i64 13 }


define void @"kira_native_impl_0"() {
entry:
  %r0 = load %kira.string, ptr @kira_str_0
  %str.ptr.0 = extractvalue %kira.string %r0, 0
  %str.len.0 = extractvalue %kira.string %r0, 1
  call void @"kira_native_print_string"(ptr %str.ptr.0, i64 %str.len.0)
  %rt.result.1 = alloca %kira.bridge.value
  call void @"kira_hybrid_call_runtime"(i32 1, ptr null, i32 0, ptr %rt.result.1)
  ret void
}

define void @"kira_native_impl_2"() {
entry:
  %r0 = load %kira.string, ptr @kira_str_1
  %str.ptr.0 = extractvalue %kira.string %r0, 0
  %str.len.0 = extractvalue %kira.string %r0, 1
  call void @"kira_native_print_string"(ptr %str.ptr.0, i64 %str.len.0)
  ret void
}

define dllexport void @"kira_native_fn_0"(ptr %args, i32 %arg_count, ptr %out_result) {
entry:
  call void @"kira_native_impl_0"()
  %bridge.out.0 = insertvalue %kira.bridge.value zeroinitializer, i8 0, 0
  store %kira.bridge.value %bridge.out.0, ptr %out_result
  ret void
}

define dllexport void @"kira_native_fn_2"(ptr %args, i32 %arg_count, ptr %out_result) {
entry:
  call void @"kira_native_impl_2"()
  %bridge.out.0 = insertvalue %kira.bridge.value zeroinitializer, i8 0, 0
  store %kira.bridge.value %bridge.out.0, ptr %out_result
  ret void
}

