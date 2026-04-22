; ModuleID = "main"
source_filename = "main"
target triple = "x86_64-pc-windows-msvc"

%t.sapp_event = type { i64, i32, i32, i32, i8, i32, i32, float, float, float, float, float, float, i32, [8 x %t.sapp_touchpoint], i32, i32, i32, i32 }
%t.sapp_touchpoint = type { i64, float, float, i32, i8 }
%t.sg_shader_function = type { ptr, %t.sg_range, ptr, ptr, ptr }
%t.sapp_logger = type { ptr, ptr }
%t.sg_wgpu_swapchain = type { ptr, ptr, ptr }
%t.AppState = type { %t.sg_shader, %t.sg_pipeline, i32, i32 }
%t.sg_vertex_attr_state = type { i32, i32, i32 }
%t.sapp_gl_desc = type { i32, i32 }
%t.sg_metal_desc = type { i8, i8 }
%t.sapp_html5_desc = type { ptr, i8, i8, i8, i8, i8, i8, i8, i8, i8, i8, i8, i8 }
%t.sg_range = type { ptr, i64 }
%t.sg_shader_storage_image_view = type { i32, i32, i32, i8, i8, i8, i8, i8, i8 }
%t.sg_color = type { float, float, float, float }
%t.sg_glsl_shader_uniform = type { i32, i16, ptr }
%t.sg_metal_environment = type { ptr }
%t.sg_shader_sampler = type { i32, i32, i8, i8, i8, i8 }
%t.sg_wgpu_desc = type { i8, i32 }
%t.sg_environment_defaults = type { i32, i32, i32 }
%t.sg_d3d11_environment = type { ptr, ptr }
%t.sg_environment = type { %t.sg_environment_defaults, %t.sg_metal_environment, %t.sg_d3d11_environment, %t.sg_wgpu_environment, %t.sg_vulkan_environment }
%t.sg_gl_swapchain = type { i32 }
%t.sg_pass = type { i32, i8, %t.sg_pass_action, %t.sg_attachments, %t.sg_swapchain, ptr, i32 }
%t.sg_shader_view = type { %t.sg_shader_texture_view, %t.sg_shader_storage_buffer_view, %t.sg_shader_storage_image_view }
%t.sg_shader_vertex_attr = type { i32, ptr, ptr, i8 }
%t.sg_swapchain = type { i32, i32, i32, i32, i32, %t.sg_metal_swapchain, %t.sg_d3d11_swapchain, %t.sg_wgpu_swapchain, %t.sg_vulkan_swapchain, %t.sg_gl_swapchain }
%t.sapp_desc = type { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, i32, i32, i32, i32, i8, i8, i8, ptr, i8, i32, i8, i32, i32, %t.sapp_icon_desc, %t.sapp_allocator, %t.sapp_logger, %t.sapp_gl_desc, %t.sapp_win32_desc, %t.sapp_html5_desc, %t.sapp_ios_desc }
%t.sg_pipeline = type { i32 }
%t.sg_pipeline_desc = type { i32, i8, %t.sg_shader, %t.sg_vertex_layout_state, %t.sg_depth_state, %t.sg_stencil_state, i32, [8 x %t.sg_color_target_state], i32, i32, i32, i32, i32, %t.sg_color, i8, ptr, i32 }
%t.sapp_range = type { ptr, i64 }
%t.sg_shader_desc = type { i32, %t.sg_shader_function, %t.sg_shader_function, %t.sg_shader_function, [16 x %t.sg_shader_vertex_attr], [8 x %t.sg_shader_uniform_block], [32 x %t.sg_shader_view], [12 x %t.sg_shader_sampler], [32 x %t.sg_shader_texture_sampler_pair], %t.sg_mtl_shader_threads_per_threadgroup, ptr, i32 }
%t.sg_stencil_state = type { i8, %t.sg_stencil_face_state, %t.sg_stencil_face_state, i8, i8, i8 }
%t.sg_view = type { i32 }
%t.sg_desc = type { i32, i32, i32, i32, i32, i32, i32, i32, i32, i8, i8, %t.sg_d3d11_desc, %t.sg_metal_desc, %t.sg_wgpu_desc, %t.sg_vulkan_desc, %t.sg_allocator, %t.sg_logger, %t.sg_environment, i32 }
%t.sg_shader_storage_buffer_view = type { i32, i8, i8, i8, i8, i8, i8, i8 }
%t.sg_d3d11_desc = type { i8 }
%t.sg_depth_attachment_action = type { i32, i32, float }
%t.sg_depth_state = type { i32, i32, i8, float, float, float }
%t.sapp_ios_desc = type { i8 }
%t.sg_shader = type { i32 }
%t.sg_mtl_shader_threads_per_threadgroup = type { i32, i32, i32 }
%t.sg_d3d11_swapchain = type { ptr, ptr, ptr }
%t.sg_shader_texture_view = type { i32, i32, i32, i8, i8, i8, i8, i8 }
%t.sg_color_attachment_action = type { i32, i32, %t.sg_color }
%t.sg_wgpu_environment = type { ptr }
%t.sg_stencil_attachment_action = type { i32, i32, i8 }
%t.sg_metal_swapchain = type { ptr, ptr, ptr }
%t.sg_allocator = type { ptr, ptr, ptr }
%t.sg_vertex_layout_state = type { [8 x %t.sg_vertex_buffer_layout_state], [16 x %t.sg_vertex_attr_state] }
%t.sg_pass_action = type { [8 x %t.sg_color_attachment_action], %t.sg_depth_attachment_action, %t.sg_stencil_attachment_action }
%t.sg_shader_uniform_block = type { i32, i32, i8, i8, i8, i8, i32, [16 x %t.sg_glsl_shader_uniform] }
%t.sg_logger = type { ptr, ptr }
%t.sg_vulkan_swapchain = type { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }
%t.sg_blend_state = type { i8, i32, i32, i32, i32, i32, i32 }
%t.sapp_win32_desc = type { i8, i8, i8 }
%t.sg_vulkan_environment = type { ptr, ptr, ptr, ptr, i32 }
%t.sapp_allocator = type { ptr, ptr, ptr }
%t.sapp_icon_desc = type { i8, [8 x %t.sapp_image_desc] }
%t.sapp_image_desc = type { i32, i32, i32, i32, %t.sapp_range }
%t.sg_shader_texture_sampler_pair = type { i32, i8, i8, ptr }
%t.sg_vertex_buffer_layout_state = type { i32, i32, i32 }
%t.sg_attachments = type { [8 x %t.sg_view], [8 x %t.sg_view], %t.sg_view }
%t.sg_stencil_face_state = type { i32, i32, i32, i32 }
%t.sg_color_target_state = type { i32, i32, %t.sg_blend_state }
%t.sg_vulkan_desc = type { i32, i32, i32 }

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
declare i32 @"sapp_height"()

declare void @"sapp_run"(ptr)

declare i32 @"sapp_width"()

declare void @"sg_apply_pipeline"(%t.sg_pipeline)

declare void @"sg_apply_viewport"(i32, i32, i32, i32, i1)

declare void @"sg_begin_pass"(ptr)

declare void @"sg_commit"()

declare void @"sg_destroy_pipeline"(%t.sg_pipeline)

declare void @"sg_destroy_shader"(%t.sg_shader)

declare void @"sg_draw"(i32, i32, i32)

declare void @"sg_end_pass"()

declare %t.sg_pipeline @"sg_make_pipeline"(ptr)

declare %t.sg_shader @"sg_make_shader"(ptr)

declare void @"sg_setup"(ptr)

declare void @"sg_shutdown"()

declare %t.sg_environment @"sglue_environment"()

declare %t.sg_swapchain @"sglue_swapchain"()



@kira_str_0_data = private unnamed_addr constant [20 x i8] c"Kira Sokol Triangle\00"

@kira_str_0 = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([20 x i8], ptr @kira_str_0_data, i64 0, i64 0), i64 19 }

@kira_str_1_data = private unnamed_addr constant [378 x i8] c"#version 330\0Aout vec4 color;\0Aconst vec2 positions[3] = vec2[3](\0A    vec2(0.0, 0.55),\0A    vec2(0.55, -0.55),\0A    vec2(-0.55, -0.55)\0D\0A);\0D\0Aconst vec4 colors[3] = vec4[3](\0D\0A    vec4(1.0, 0.25, 0.25, 1.0),\0D\0A    vec4(0.25, 1.0, 0.35, 1.0),\0D\0A    vec4(0.25, 0.45, 1.0, 1.0)\0D\0A);\0D\0Avoid main() {\0A    gl_Position = vec4(positions[gl_VertexID], 0.0, 1.0);\0A    color = colors[gl_VertexID];\0A}\00"

@kira_str_1 = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([378 x i8], ptr @kira_str_1_data, i64 0, i64 0), i64 377 }

@kira_str_2_data = private unnamed_addr constant [89 x i8] c"#version 330\0Ain vec4 color;\0Aout vec4 frag_color;\0Avoid main() {\0A    frag_color = color;\0A}\00"

@kira_str_2 = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([89 x i8], ptr @kira_str_2_data, i64 0, i64 0), i64 88 }


define void @"kira_fn_0_main"() {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  %local.size.ptr.1 = getelementptr inbounds %t.sapp_desc, ptr null, i32 1
  %local.size.1 = ptrtoint ptr %local.size.ptr.1 to i64
  %local.heap.1 = call ptr @malloc(i64 %local.size.1)
  store %t.sapp_desc zeroinitializer, ptr %local.heap.1
  %local.heap.int.1 = ptrtoint ptr %local.heap.1 to i64
  store i64 %local.heap.int.1, ptr %local1
  %alloc.size.ptr.0 = getelementptr inbounds %t.AppState, ptr null, i32 1
  %alloc.size.0 = ptrtoint ptr %alloc.size.ptr.0 to i64
  %alloc.ptr.0 = call ptr @malloc(i64 %alloc.size.0)
  store %t.AppState zeroinitializer, ptr %alloc.ptr.0
  %r0 = ptrtoint ptr %alloc.ptr.0 to i64
  %alloc.size.ptr.1 = getelementptr inbounds %t.sg_shader, ptr null, i32 1
  %alloc.size.1 = ptrtoint ptr %alloc.size.ptr.1 to i64
  %alloc.ptr.1 = call ptr @malloc(i64 %alloc.size.1)
  store %t.sg_shader zeroinitializer, ptr %alloc.ptr.1
  %r1 = ptrtoint ptr %alloc.ptr.1 to i64
  %field.base.2 = inttoptr i64 %r0 to ptr
  %field.ptr.2 = getelementptr inbounds %t.AppState, ptr %field.base.2, i32 0, i32 0
  %r2 = ptrtoint ptr %field.ptr.2 to i64
  %copy.dst.2 = inttoptr i64 %r2 to ptr
  %copy.src.1 = inttoptr i64 %r1 to ptr
  %copy.val.2 = load %t.sg_shader, ptr %copy.src.1
  store %t.sg_shader %copy.val.2, ptr %copy.dst.2
  %alloc.size.ptr.3 = getelementptr inbounds %t.sg_pipeline, ptr null, i32 1
  %alloc.size.3 = ptrtoint ptr %alloc.size.ptr.3 to i64
  %alloc.ptr.3 = call ptr @malloc(i64 %alloc.size.3)
  store %t.sg_pipeline zeroinitializer, ptr %alloc.ptr.3
  %r3 = ptrtoint ptr %alloc.ptr.3 to i64
  %field.base.4 = inttoptr i64 %r0 to ptr
  %field.ptr.4 = getelementptr inbounds %t.AppState, ptr %field.base.4, i32 0, i32 1
  %r4 = ptrtoint ptr %field.ptr.4 to i64
  %copy.dst.4 = inttoptr i64 %r4 to ptr
  %copy.src.3 = inttoptr i64 %r3 to ptr
  %copy.val.4 = load %t.sg_pipeline, ptr %copy.src.3
  store %t.sg_pipeline %copy.val.4, ptr %copy.dst.4
  %r5 = add i64 0, 128
  %field.base.6 = inttoptr i64 %r0 to ptr
  %field.ptr.6 = getelementptr inbounds %t.AppState, ptr %field.base.6, i32 0, i32 2
  %r6 = ptrtoint ptr %field.ptr.6 to i64
  %store.ptr.5 = inttoptr i64 %r6 to ptr
  %store.cast.5 = trunc i64 %r5 to i32
  store i32 %store.cast.5, ptr %store.ptr.5
  %r7 = add i64 0, 128
  %field.base.8 = inttoptr i64 %r0 to ptr
  %field.ptr.8 = getelementptr inbounds %t.AppState, ptr %field.base.8, i32 0, i32 3
  %r8 = ptrtoint ptr %field.ptr.8 to i64
  %store.ptr.7 = inttoptr i64 %r8 to ptr
  %store.cast.7 = trunc i64 %r7 to i32
  store i32 %store.cast.7, ptr %store.ptr.7
  %native.state.size.ptr.9 = getelementptr inbounds [4 x %kira.bridge.value], ptr null, i32 1
  %native.state.size.9 = ptrtoint ptr %native.state.size.ptr.9 to i64
  %native.state.box.9 = call ptr @"kira_native_state_alloc"(i64 530113222467764049, i64 %native.state.size.9)
  %native.state.payload.9 = call ptr @"kira_native_state_payload"(ptr %native.state.box.9)
  %native.state.src.9 = inttoptr i64 %r0 to ptr
  %native.state.src.field.ptr.9.0 = getelementptr inbounds %t.AppState, ptr %native.state.src.9, i32 0, i32 0
  %native.state.slot.ptr.9.0 = getelementptr inbounds %kira.bridge.value, ptr %native.state.payload.9, i64 0
  %native.state.pack.9.0.0 = insertvalue %kira.bridge.value zeroinitializer, i8 5, 0
  %native.state.load.struct.9.0 = load %t.sg_shader, ptr %native.state.src.field.ptr.9.0
  %native.state.load.struct.size.ptr.9.0 = getelementptr inbounds %t.sg_shader, ptr null, i32 1
  %native.state.load.struct.size.9.0 = ptrtoint ptr %native.state.load.struct.size.ptr.9.0 to i64
  %native.state.load.struct.copy.9.0 = call ptr @malloc(i64 %native.state.load.struct.size.9.0)
  store %t.sg_shader %native.state.load.struct.9.0, ptr %native.state.load.struct.copy.9.0
  %native.state.load.struct.ptrint.9.0 = ptrtoint ptr %native.state.load.struct.copy.9.0 to i64
  %native.state.pack.9.0 = insertvalue %kira.bridge.value %native.state.pack.9.0.0, i64 %native.state.load.struct.ptrint.9.0, 2
  store %kira.bridge.value %native.state.pack.9.0, ptr %native.state.slot.ptr.9.0
  %native.state.src.field.ptr.9.1 = getelementptr inbounds %t.AppState, ptr %native.state.src.9, i32 0, i32 1
  %native.state.slot.ptr.9.1 = getelementptr inbounds %kira.bridge.value, ptr %native.state.payload.9, i64 1
  %native.state.pack.9.1.0 = insertvalue %kira.bridge.value zeroinitializer, i8 5, 0
  %native.state.load.struct.9.1 = load %t.sg_pipeline, ptr %native.state.src.field.ptr.9.1
  %native.state.load.struct.size.ptr.9.1 = getelementptr inbounds %t.sg_pipeline, ptr null, i32 1
  %native.state.load.struct.size.9.1 = ptrtoint ptr %native.state.load.struct.size.ptr.9.1 to i64
  %native.state.load.struct.copy.9.1 = call ptr @malloc(i64 %native.state.load.struct.size.9.1)
  store %t.sg_pipeline %native.state.load.struct.9.1, ptr %native.state.load.struct.copy.9.1
  %native.state.load.struct.ptrint.9.1 = ptrtoint ptr %native.state.load.struct.copy.9.1 to i64
  %native.state.pack.9.1 = insertvalue %kira.bridge.value %native.state.pack.9.1.0, i64 %native.state.load.struct.ptrint.9.1, 2
  store %kira.bridge.value %native.state.pack.9.1, ptr %native.state.slot.ptr.9.1
  %native.state.src.field.ptr.9.2 = getelementptr inbounds %t.AppState, ptr %native.state.src.9, i32 0, i32 2
  %native.state.slot.ptr.9.2 = getelementptr inbounds %kira.bridge.value, ptr %native.state.payload.9, i64 2
  %native.state.pack.9.2.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.load.int.9.2 = load i32, ptr %native.state.src.field.ptr.9.2
  %native.state.load.int.ext.9.2 = sext i32 %native.state.load.int.9.2 to i64
  %native.state.pack.9.2 = insertvalue %kira.bridge.value %native.state.pack.9.2.0, i64 %native.state.load.int.ext.9.2, 2
  store %kira.bridge.value %native.state.pack.9.2, ptr %native.state.slot.ptr.9.2
  %native.state.src.field.ptr.9.3 = getelementptr inbounds %t.AppState, ptr %native.state.src.9, i32 0, i32 3
  %native.state.slot.ptr.9.3 = getelementptr inbounds %kira.bridge.value, ptr %native.state.payload.9, i64 3
  %native.state.pack.9.3.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.load.int.9.3 = load i32, ptr %native.state.src.field.ptr.9.3
  %native.state.load.int.ext.9.3 = sext i32 %native.state.load.int.9.3 to i64
  %native.state.pack.9.3 = insertvalue %kira.bridge.value %native.state.pack.9.3.0, i64 %native.state.load.int.ext.9.3, 2
  store %kira.bridge.value %native.state.pack.9.3, ptr %native.state.slot.ptr.9.3
  %r9 = ptrtoint ptr %native.state.box.9 to i64
  store i64 %r9, ptr %local0
  %alloc.size.ptr.10 = getelementptr inbounds %t.sapp_desc, ptr null, i32 1
  %alloc.size.10 = ptrtoint ptr %alloc.size.ptr.10 to i64
  %alloc.ptr.10 = call ptr @malloc(i64 %alloc.size.10)
  store %t.sapp_desc zeroinitializer, ptr %alloc.ptr.10
  %r10 = ptrtoint ptr %alloc.ptr.10 to i64
  %r11 = ptrtoint ptr @"kira_fn_1_init" to i64
  %field.base.12 = inttoptr i64 %r10 to ptr
  %field.ptr.12 = getelementptr inbounds %t.sapp_desc, ptr %field.base.12, i32 0, i32 5
  %r12 = ptrtoint ptr %field.ptr.12 to i64
  %store.ptr.11 = inttoptr i64 %r12 to ptr
  %store.rawptr.11 = inttoptr i64 %r11 to ptr
  store ptr %store.rawptr.11, ptr %store.ptr.11
  %r13 = ptrtoint ptr @"kira_fn_2_frame" to i64
  %field.base.14 = inttoptr i64 %r10 to ptr
  %field.ptr.14 = getelementptr inbounds %t.sapp_desc, ptr %field.base.14, i32 0, i32 6
  %r14 = ptrtoint ptr %field.ptr.14 to i64
  %store.ptr.13 = inttoptr i64 %r14 to ptr
  %store.rawptr.13 = inttoptr i64 %r13 to ptr
  store ptr %store.rawptr.13, ptr %store.ptr.13
  %r15 = ptrtoint ptr @"kira_fn_4_cleanup" to i64
  %field.base.16 = inttoptr i64 %r10 to ptr
  %field.ptr.16 = getelementptr inbounds %t.sapp_desc, ptr %field.base.16, i32 0, i32 7
  %r16 = ptrtoint ptr %field.ptr.16 to i64
  %store.ptr.15 = inttoptr i64 %r16 to ptr
  %store.rawptr.15 = inttoptr i64 %r15 to ptr
  store ptr %store.rawptr.15, ptr %store.ptr.15
  %r17 = ptrtoint ptr @"kira_fn_3_event" to i64
  %field.base.18 = inttoptr i64 %r10 to ptr
  %field.ptr.18 = getelementptr inbounds %t.sapp_desc, ptr %field.base.18, i32 0, i32 8
  %r18 = ptrtoint ptr %field.ptr.18 to i64
  %store.ptr.17 = inttoptr i64 %r18 to ptr
  %store.rawptr.17 = inttoptr i64 %r17 to ptr
  store ptr %store.rawptr.17, ptr %store.ptr.17
  %r19 = load i64, ptr %local0
  %field.base.20 = inttoptr i64 %r10 to ptr
  %field.ptr.20 = getelementptr inbounds %t.sapp_desc, ptr %field.base.20, i32 0, i32 4
  %r20 = ptrtoint ptr %field.ptr.20 to i64
  %store.ptr.19 = inttoptr i64 %r20 to ptr
  %store.rawptr.19 = inttoptr i64 %r19 to ptr
  store ptr %store.rawptr.19, ptr %store.ptr.19
  %r21 = add i64 0, 640
  %field.base.22 = inttoptr i64 %r10 to ptr
  %field.ptr.22 = getelementptr inbounds %t.sapp_desc, ptr %field.base.22, i32 0, i32 9
  %r22 = ptrtoint ptr %field.ptr.22 to i64
  %store.ptr.21 = inttoptr i64 %r22 to ptr
  %store.cast.21 = trunc i64 %r21 to i32
  store i32 %store.cast.21, ptr %store.ptr.21
  %r23 = add i64 0, 480
  %field.base.24 = inttoptr i64 %r10 to ptr
  %field.ptr.24 = getelementptr inbounds %t.sapp_desc, ptr %field.base.24, i32 0, i32 10
  %r24 = ptrtoint ptr %field.ptr.24 to i64
  %store.ptr.23 = inttoptr i64 %r24 to ptr
  %store.cast.23 = trunc i64 %r23 to i32
  store i32 %store.cast.23, ptr %store.ptr.23
  %r25 = load %kira.string, ptr @kira_str_0
  %field.base.26 = inttoptr i64 %r10 to ptr
  %field.ptr.26 = getelementptr inbounds %t.sapp_desc, ptr %field.base.26, i32 0, i32 16
  %r26 = ptrtoint ptr %field.ptr.26 to i64
  %store.ptr.25 = inttoptr i64 %r26 to ptr
  %store.cstr.25 = extractvalue %kira.string %r25, 0
  store ptr %store.cstr.25, ptr %store.ptr.25
  %r27 = load i64, ptr %local1
  %copy.dst.27 = inttoptr i64 %r27 to ptr
  %copy.src.10 = inttoptr i64 %r10 to ptr
  %copy.val.27 = load %t.sapp_desc, ptr %copy.src.10
  store %t.sapp_desc %copy.val.27, ptr %copy.dst.27
  %r28 = load i64, ptr %local1
  %call.arg.44.0 = inttoptr i64 %r28 to ptr
  call void @"sapp_run"(ptr %call.arg.44.0)
  ret void
}

define void @"kira_fn_1_init"(i64 %arg0) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  %local2 = alloca i64
  %local.size.ptr.2 = getelementptr inbounds %t.sg_desc, ptr null, i32 1
  %local.size.2 = ptrtoint ptr %local.size.ptr.2 to i64
  %local.heap.2 = call ptr @malloc(i64 %local.size.2)
  store %t.sg_desc zeroinitializer, ptr %local.heap.2
  %local.heap.int.2 = ptrtoint ptr %local.heap.2 to i64
  store i64 %local.heap.int.2, ptr %local2
  %local3 = alloca i64
  %local.size.ptr.3 = getelementptr inbounds %t.sg_shader_desc, ptr null, i32 1
  %local.size.3 = ptrtoint ptr %local.size.ptr.3 to i64
  %local.heap.3 = call ptr @malloc(i64 %local.size.3)
  store %t.sg_shader_desc zeroinitializer, ptr %local.heap.3
  %local.heap.int.3 = ptrtoint ptr %local.heap.3 to i64
  store i64 %local.heap.int.3, ptr %local3
  %local4 = alloca i64
  %local.size.ptr.4 = getelementptr inbounds %t.sg_pipeline_desc, ptr null, i32 1
  %local.size.4 = ptrtoint ptr %local.size.ptr.4 to i64
  %local.heap.4 = call ptr @malloc(i64 %local.size.4)
  store %t.sg_pipeline_desc zeroinitializer, ptr %local.heap.4
  %local.heap.int.4 = ptrtoint ptr %local.heap.4 to i64
  store i64 %local.heap.int.4, ptr %local4
  store i64 %arg0, ptr %local0
  %r0 = load i64, ptr %local0
  %native.recover.state.1 = inttoptr i64 %r0 to ptr
  %native.recover.payload.1 = call ptr @"kira_native_state_recover"(ptr %native.recover.state.1, i64 530113222467764049)
  %r1 = ptrtoint ptr %native.recover.payload.1 to i64
  store i64 %r1, ptr %local1
  %call.int.2 = call i32 @"sapp_width"()
  %r2.sext = sext i32 %call.int.2 to i64
  %r2 = add i64 %r2.sext, 0
  %r3 = load i64, ptr %local1
  %native.state.set.ptr.2 = inttoptr i64 %r3 to ptr
  %native.state.set.slot.2 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.2, i64 2
  %native.state.set.pack.0.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.set.pack.0 = insertvalue %kira.bridge.value %native.state.set.pack.0.0, i64 %r2, 2
  store %kira.bridge.value %native.state.set.pack.0, ptr %native.state.set.slot.2
  %call.int.4 = call i32 @"sapp_height"()
  %r4.sext = sext i32 %call.int.4 to i64
  %r4 = add i64 %r4.sext, 0
  %r5 = load i64, ptr %local1
  %native.state.set.ptr.4 = inttoptr i64 %r5 to ptr
  %native.state.set.slot.4 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.4, i64 3
  %native.state.set.pack.1.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.set.pack.1 = insertvalue %kira.bridge.value %native.state.set.pack.1.0, i64 %r4, 2
  store %kira.bridge.value %native.state.set.pack.1, ptr %native.state.set.slot.4
  %alloc.size.ptr.6 = getelementptr inbounds %t.sg_desc, ptr null, i32 1
  %alloc.size.6 = ptrtoint ptr %alloc.size.ptr.6 to i64
  %alloc.ptr.6 = call ptr @malloc(i64 %alloc.size.6)
  store %t.sg_desc zeroinitializer, ptr %alloc.ptr.6
  %r6 = ptrtoint ptr %alloc.ptr.6 to i64
  %call.struct.7 = call %t.sg_environment @"sglue_environment"()
  %call.ret.ptr.7 = alloca %t.sg_environment
  store %t.sg_environment %call.struct.7, ptr %call.ret.ptr.7
  %r7 = ptrtoint ptr %call.ret.ptr.7 to i64
  %field.base.8 = inttoptr i64 %r6 to ptr
  %field.ptr.8 = getelementptr inbounds %t.sg_desc, ptr %field.base.8, i32 0, i32 17
  %r8 = ptrtoint ptr %field.ptr.8 to i64
  %copy.dst.8 = inttoptr i64 %r8 to ptr
  %copy.src.7 = inttoptr i64 %r7 to ptr
  %copy.val.8 = load %t.sg_environment, ptr %copy.src.7
  store %t.sg_environment %copy.val.8, ptr %copy.dst.8
  %r9 = load i64, ptr %local2
  %copy.dst.9 = inttoptr i64 %r9 to ptr
  %copy.src.6 = inttoptr i64 %r6 to ptr
  %copy.val.9 = load %t.sg_desc, ptr %copy.src.6
  store %t.sg_desc %copy.val.9, ptr %copy.dst.9
  %r10 = load i64, ptr %local2
  %call.arg.188.0 = inttoptr i64 %r10 to ptr
  call void @"sg_setup"(ptr %call.arg.188.0)
  %alloc.size.ptr.11 = getelementptr inbounds %t.sg_shader_desc, ptr null, i32 1
  %alloc.size.11 = ptrtoint ptr %alloc.size.ptr.11 to i64
  %alloc.ptr.11 = call ptr @malloc(i64 %alloc.size.11)
  store %t.sg_shader_desc zeroinitializer, ptr %alloc.ptr.11
  %r11 = ptrtoint ptr %alloc.ptr.11 to i64
  %alloc.size.ptr.12 = getelementptr inbounds %t.sg_shader_function, ptr null, i32 1
  %alloc.size.12 = ptrtoint ptr %alloc.size.ptr.12 to i64
  %alloc.ptr.12 = call ptr @malloc(i64 %alloc.size.12)
  store %t.sg_shader_function zeroinitializer, ptr %alloc.ptr.12
  %r12 = ptrtoint ptr %alloc.ptr.12 to i64
  %r13 = load %kira.string, ptr @kira_str_1
  %field.base.14 = inttoptr i64 %r12 to ptr
  %field.ptr.14 = getelementptr inbounds %t.sg_shader_function, ptr %field.base.14, i32 0, i32 0
  %r14 = ptrtoint ptr %field.ptr.14 to i64
  %store.ptr.13 = inttoptr i64 %r14 to ptr
  %store.cstr.13 = extractvalue %kira.string %r13, 0
  store ptr %store.cstr.13, ptr %store.ptr.13
  %field.base.15 = inttoptr i64 %r11 to ptr
  %field.ptr.15 = getelementptr inbounds %t.sg_shader_desc, ptr %field.base.15, i32 0, i32 1
  %r15 = ptrtoint ptr %field.ptr.15 to i64
  %copy.dst.15 = inttoptr i64 %r15 to ptr
  %copy.src.12 = inttoptr i64 %r12 to ptr
  %copy.val.15 = load %t.sg_shader_function, ptr %copy.src.12
  store %t.sg_shader_function %copy.val.15, ptr %copy.dst.15
  %alloc.size.ptr.16 = getelementptr inbounds %t.sg_shader_function, ptr null, i32 1
  %alloc.size.16 = ptrtoint ptr %alloc.size.ptr.16 to i64
  %alloc.ptr.16 = call ptr @malloc(i64 %alloc.size.16)
  store %t.sg_shader_function zeroinitializer, ptr %alloc.ptr.16
  %r16 = ptrtoint ptr %alloc.ptr.16 to i64
  %r17 = load %kira.string, ptr @kira_str_2
  %field.base.18 = inttoptr i64 %r16 to ptr
  %field.ptr.18 = getelementptr inbounds %t.sg_shader_function, ptr %field.base.18, i32 0, i32 0
  %r18 = ptrtoint ptr %field.ptr.18 to i64
  %store.ptr.17 = inttoptr i64 %r18 to ptr
  %store.cstr.17 = extractvalue %kira.string %r17, 0
  store ptr %store.cstr.17, ptr %store.ptr.17
  %field.base.19 = inttoptr i64 %r11 to ptr
  %field.ptr.19 = getelementptr inbounds %t.sg_shader_desc, ptr %field.base.19, i32 0, i32 2
  %r19 = ptrtoint ptr %field.ptr.19 to i64
  %copy.dst.19 = inttoptr i64 %r19 to ptr
  %copy.src.16 = inttoptr i64 %r16 to ptr
  %copy.val.19 = load %t.sg_shader_function, ptr %copy.src.16
  store %t.sg_shader_function %copy.val.19, ptr %copy.dst.19
  %r20 = load i64, ptr %local3
  %copy.dst.20 = inttoptr i64 %r20 to ptr
  %copy.src.11 = inttoptr i64 %r11 to ptr
  %copy.val.20 = load %t.sg_shader_desc, ptr %copy.src.11
  store %t.sg_shader_desc %copy.val.20, ptr %copy.dst.20
  %r21 = load i64, ptr %local3
  %call.arg.126.0 = inttoptr i64 %r21 to ptr
  %call.struct.22 = call %t.sg_shader @"sg_make_shader"(ptr %call.arg.126.0)
  %call.ret.ptr.22 = alloca %t.sg_shader
  store %t.sg_shader %call.struct.22, ptr %call.ret.ptr.22
  %r22 = ptrtoint ptr %call.ret.ptr.22 to i64
  %r23 = load i64, ptr %local1
  %native.state.set.ptr.22 = inttoptr i64 %r23 to ptr
  %native.state.set.slot.22 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.22, i64 0
  %native.state.set.pack.2.0 = insertvalue %kira.bridge.value zeroinitializer, i8 5, 0
  %native.state.set.struct.src.2 = inttoptr i64 %r22 to ptr
  %native.state.set.struct.value.2 = load %t.sg_shader, ptr %native.state.set.struct.src.2
  %native.state.set.struct.size.ptr.2 = getelementptr inbounds %t.sg_shader, ptr null, i32 1
  %native.state.set.struct.size.2 = ptrtoint ptr %native.state.set.struct.size.ptr.2 to i64
  %native.state.set.struct.copy.2 = call ptr @malloc(i64 %native.state.set.struct.size.2)
  store %t.sg_shader %native.state.set.struct.value.2, ptr %native.state.set.struct.copy.2
  %native.state.set.struct.ptrint.2 = ptrtoint ptr %native.state.set.struct.copy.2 to i64
  %native.state.set.pack.2 = insertvalue %kira.bridge.value %native.state.set.pack.2.0, i64 %native.state.set.struct.ptrint.2, 2
  store %kira.bridge.value %native.state.set.pack.2, ptr %native.state.set.slot.22
  %alloc.size.ptr.24 = getelementptr inbounds %t.sg_pipeline_desc, ptr null, i32 1
  %alloc.size.24 = ptrtoint ptr %alloc.size.ptr.24 to i64
  %alloc.ptr.24 = call ptr @malloc(i64 %alloc.size.24)
  store %t.sg_pipeline_desc zeroinitializer, ptr %alloc.ptr.24
  %r24 = ptrtoint ptr %alloc.ptr.24 to i64
  %r25 = load i64, ptr %local1
  %native.state.get.ptr.26 = inttoptr i64 %r25 to ptr
  %native.state.get.slot.26 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.26, i64 0
  %native.state.get.val.3 = load %kira.bridge.value, ptr %native.state.get.slot.26
  %r26 = extractvalue %kira.bridge.value %native.state.get.val.3, 2
  %field.base.27 = inttoptr i64 %r24 to ptr
  %field.ptr.27 = getelementptr inbounds %t.sg_pipeline_desc, ptr %field.base.27, i32 0, i32 2
  %r27 = ptrtoint ptr %field.ptr.27 to i64
  %copy.dst.27 = inttoptr i64 %r27 to ptr
  %copy.src.26 = inttoptr i64 %r26 to ptr
  %copy.val.27 = load %t.sg_shader, ptr %copy.src.26
  store %t.sg_shader %copy.val.27, ptr %copy.dst.27
  %r28 = load i64, ptr %local4
  %copy.dst.28 = inttoptr i64 %r28 to ptr
  %copy.src.24 = inttoptr i64 %r24 to ptr
  %copy.val.28 = load %t.sg_pipeline_desc, ptr %copy.src.24
  store %t.sg_pipeline_desc %copy.val.28, ptr %copy.dst.28
  %r29 = load i64, ptr %local4
  %call.arg.124.0 = inttoptr i64 %r29 to ptr
  %call.struct.30 = call %t.sg_pipeline @"sg_make_pipeline"(ptr %call.arg.124.0)
  %call.ret.ptr.30 = alloca %t.sg_pipeline
  store %t.sg_pipeline %call.struct.30, ptr %call.ret.ptr.30
  %r30 = ptrtoint ptr %call.ret.ptr.30 to i64
  %r31 = load i64, ptr %local1
  %native.state.set.ptr.30 = inttoptr i64 %r31 to ptr
  %native.state.set.slot.30 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.30, i64 1
  %native.state.set.pack.4.0 = insertvalue %kira.bridge.value zeroinitializer, i8 5, 0
  %native.state.set.struct.src.4 = inttoptr i64 %r30 to ptr
  %native.state.set.struct.value.4 = load %t.sg_pipeline, ptr %native.state.set.struct.src.4
  %native.state.set.struct.size.ptr.4 = getelementptr inbounds %t.sg_pipeline, ptr null, i32 1
  %native.state.set.struct.size.4 = ptrtoint ptr %native.state.set.struct.size.ptr.4 to i64
  %native.state.set.struct.copy.4 = call ptr @malloc(i64 %native.state.set.struct.size.4)
  store %t.sg_pipeline %native.state.set.struct.value.4, ptr %native.state.set.struct.copy.4
  %native.state.set.struct.ptrint.4 = ptrtoint ptr %native.state.set.struct.copy.4 to i64
  %native.state.set.pack.4 = insertvalue %kira.bridge.value %native.state.set.pack.4.0, i64 %native.state.set.struct.ptrint.4, 2
  store %kira.bridge.value %native.state.set.pack.4, ptr %native.state.set.slot.30
  ret void
}

define void @"kira_fn_2_frame"(i64 %arg0) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  %local2 = alloca i64
  %local.size.ptr.2 = getelementptr inbounds %t.sg_pass, ptr null, i32 1
  %local.size.2 = ptrtoint ptr %local.size.ptr.2 to i64
  %local.heap.2 = call ptr @malloc(i64 %local.size.2)
  store %t.sg_pass zeroinitializer, ptr %local.heap.2
  %local.heap.int.2 = ptrtoint ptr %local.heap.2 to i64
  store i64 %local.heap.int.2, ptr %local2
  store i64 %arg0, ptr %local0
  %r0 = load i64, ptr %local0
  %native.recover.state.1 = inttoptr i64 %r0 to ptr
  %native.recover.payload.1 = call ptr @"kira_native_state_recover"(ptr %native.recover.state.1, i64 530113222467764049)
  %r1 = ptrtoint ptr %native.recover.payload.1 to i64
  store i64 %r1, ptr %local1
  %call.int.2 = call i32 @"sapp_width"()
  %r2.sext = sext i32 %call.int.2 to i64
  %r2 = add i64 %r2.sext, 0
  %r3 = load i64, ptr %local1
  %native.state.set.ptr.2 = inttoptr i64 %r3 to ptr
  %native.state.set.slot.2 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.2, i64 2
  %native.state.set.pack.0.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.set.pack.0 = insertvalue %kira.bridge.value %native.state.set.pack.0.0, i64 %r2, 2
  store %kira.bridge.value %native.state.set.pack.0, ptr %native.state.set.slot.2
  %call.int.4 = call i32 @"sapp_height"()
  %r4.sext = sext i32 %call.int.4 to i64
  %r4 = add i64 %r4.sext, 0
  %r5 = load i64, ptr %local1
  %native.state.set.ptr.4 = inttoptr i64 %r5 to ptr
  %native.state.set.slot.4 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.4, i64 3
  %native.state.set.pack.1.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.set.pack.1 = insertvalue %kira.bridge.value %native.state.set.pack.1.0, i64 %r4, 2
  store %kira.bridge.value %native.state.set.pack.1, ptr %native.state.set.slot.4
  %alloc.size.ptr.6 = getelementptr inbounds %t.sg_pass, ptr null, i32 1
  %alloc.size.6 = ptrtoint ptr %alloc.size.ptr.6 to i64
  %alloc.ptr.6 = call ptr @malloc(i64 %alloc.size.6)
  store %t.sg_pass zeroinitializer, ptr %alloc.ptr.6
  %r6 = ptrtoint ptr %alloc.ptr.6 to i64
  %call.struct.7 = call %t.sg_swapchain @"sglue_swapchain"()
  %call.ret.ptr.7 = alloca %t.sg_swapchain
  store %t.sg_swapchain %call.struct.7, ptr %call.ret.ptr.7
  %r7 = ptrtoint ptr %call.ret.ptr.7 to i64
  %field.base.8 = inttoptr i64 %r6 to ptr
  %field.ptr.8 = getelementptr inbounds %t.sg_pass, ptr %field.base.8, i32 0, i32 4
  %r8 = ptrtoint ptr %field.ptr.8 to i64
  %copy.dst.8 = inttoptr i64 %r8 to ptr
  %copy.src.7 = inttoptr i64 %r7 to ptr
  %copy.val.8 = load %t.sg_swapchain, ptr %copy.src.7
  store %t.sg_swapchain %copy.val.8, ptr %copy.dst.8
  %r9 = load i64, ptr %local2
  %copy.dst.9 = inttoptr i64 %r9 to ptr
  %copy.src.6 = inttoptr i64 %r6 to ptr
  %copy.val.9 = load %t.sg_pass, ptr %copy.src.6
  store %t.sg_pass %copy.val.9, ptr %copy.dst.9
  %r10 = load i64, ptr %local2
  %call.arg.75.0 = inttoptr i64 %r10 to ptr
  call void @"sg_begin_pass"(ptr %call.arg.75.0)
  %r11 = add i64 0, 0
  %r12 = add i64 0, 0
  %r13 = load i64, ptr %local1
  %native.state.get.ptr.14 = inttoptr i64 %r13 to ptr
  %native.state.get.slot.14 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.14, i64 2
  %native.state.get.val.2 = load %kira.bridge.value, ptr %native.state.get.slot.14
  %r14 = extractvalue %kira.bridge.value %native.state.get.val.2, 2
  %r15 = load i64, ptr %local1
  %native.state.get.ptr.16 = inttoptr i64 %r15 to ptr
  %native.state.get.slot.16 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.16, i64 3
  %native.state.get.val.3 = load %kira.bridge.value, ptr %native.state.get.slot.16
  %r16 = extractvalue %kira.bridge.value %native.state.get.val.3, 2
  %r17 = add i1 0, 1
  %call.arg.73.0 = trunc i64 %r11 to i32
  %call.arg.73.1 = trunc i64 %r12 to i32
  %call.arg.73.2 = trunc i64 %r14 to i32
  %call.arg.73.3 = trunc i64 %r16 to i32
  call void @"sg_apply_viewport"(i32 %call.arg.73.0, i32 %call.arg.73.1, i32 %call.arg.73.2, i32 %call.arg.73.3, i1 %r17)
  %r18 = load i64, ptr %local1
  %native.state.get.ptr.19 = inttoptr i64 %r18 to ptr
  %native.state.get.slot.19 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.19, i64 1
  %native.state.get.val.4 = load %kira.bridge.value, ptr %native.state.get.slot.19
  %r19 = extractvalue %kira.bridge.value %native.state.get.val.4, 2
  %call.arg.ptr.69.0 = inttoptr i64 %r19 to ptr
  %call.arg.69.0 = load %t.sg_pipeline, ptr %call.arg.ptr.69.0
  call void @"sg_apply_pipeline"(%t.sg_pipeline %call.arg.69.0)
  %r20 = add i64 0, 0
  %r21 = add i64 0, 3
  %r22 = add i64 0, 1
  %call.arg.99.0 = trunc i64 %r20 to i32
  %call.arg.99.1 = trunc i64 %r21 to i32
  %call.arg.99.2 = trunc i64 %r22 to i32
  call void @"sg_draw"(i32 %call.arg.99.0, i32 %call.arg.99.1, i32 %call.arg.99.2)
  call void @"sg_end_pass"()
  call void @"sg_commit"()
  ret void
}

define void @"kira_fn_3_event"(i64 %arg0, i64 %arg1) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  %local2 = alloca i64
  store i64 %arg0, ptr %local0
  store i64 %arg1, ptr %local1
  %r0 = load i64, ptr %local1
  %native.recover.state.1 = inttoptr i64 %r0 to ptr
  %native.recover.payload.1 = call ptr @"kira_native_state_recover"(ptr %native.recover.state.1, i64 530113222467764049)
  %r1 = ptrtoint ptr %native.recover.payload.1 to i64
  store i64 %r1, ptr %local2
  %r2 = load i64, ptr %local0
  %field.base.3 = inttoptr i64 %r2 to ptr
  %field.ptr.3 = getelementptr inbounds %t.sapp_event, ptr %field.base.3, i32 0, i32 17
  %r3 = ptrtoint ptr %field.ptr.3 to i64
  %load.ptr.4 = inttoptr i64 %r3 to ptr
  %load.raw.4 = load i32, ptr %load.ptr.4
  %r4 = sext i32 %load.raw.4 to i64
  %r5 = load i64, ptr %local2
  %native.state.set.ptr.4 = inttoptr i64 %r5 to ptr
  %native.state.set.slot.4 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.4, i64 2
  %native.state.set.pack.0.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.set.pack.0 = insertvalue %kira.bridge.value %native.state.set.pack.0.0, i64 %r4, 2
  store %kira.bridge.value %native.state.set.pack.0, ptr %native.state.set.slot.4
  %r6 = load i64, ptr %local0
  %field.base.7 = inttoptr i64 %r6 to ptr
  %field.ptr.7 = getelementptr inbounds %t.sapp_event, ptr %field.base.7, i32 0, i32 18
  %r7 = ptrtoint ptr %field.ptr.7 to i64
  %load.ptr.8 = inttoptr i64 %r7 to ptr
  %load.raw.8 = load i32, ptr %load.ptr.8
  %r8 = sext i32 %load.raw.8 to i64
  %r9 = load i64, ptr %local2
  %native.state.set.ptr.8 = inttoptr i64 %r9 to ptr
  %native.state.set.slot.8 = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.8, i64 3
  %native.state.set.pack.1.0 = insertvalue %kira.bridge.value zeroinitializer, i8 1, 0
  %native.state.set.pack.1 = insertvalue %kira.bridge.value %native.state.set.pack.1.0, i64 %r8, 2
  store %kira.bridge.value %native.state.set.pack.1, ptr %native.state.set.slot.8
  ret void
}

define void @"kira_fn_4_cleanup"(i64 %arg0) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  store i64 %arg0, ptr %local0
  %r0 = load i64, ptr %local0
  %native.recover.state.1 = inttoptr i64 %r0 to ptr
  %native.recover.payload.1 = call ptr @"kira_native_state_recover"(ptr %native.recover.state.1, i64 530113222467764049)
  %r1 = ptrtoint ptr %native.recover.payload.1 to i64
  store i64 %r1, ptr %local1
  %r2 = load i64, ptr %local1
  %native.state.get.ptr.3 = inttoptr i64 %r2 to ptr
  %native.state.get.slot.3 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.3, i64 1
  %native.state.get.val.0 = load %kira.bridge.value, ptr %native.state.get.slot.3
  %r3 = extractvalue %kira.bridge.value %native.state.get.val.0, 2
  %call.arg.ptr.93.0 = inttoptr i64 %r3 to ptr
  %call.arg.93.0 = load %t.sg_pipeline, ptr %call.arg.ptr.93.0
  call void @"sg_destroy_pipeline"(%t.sg_pipeline %call.arg.93.0)
  %r4 = load i64, ptr %local1
  %native.state.get.ptr.5 = inttoptr i64 %r4 to ptr
  %native.state.get.slot.5 = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.5, i64 0
  %native.state.get.val.1 = load %kira.bridge.value, ptr %native.state.get.slot.5
  %r5 = extractvalue %kira.bridge.value %native.state.get.val.1, 2
  %call.arg.ptr.95.0 = inttoptr i64 %r5 to ptr
  %call.arg.95.0 = load %t.sg_shader, ptr %call.arg.ptr.95.0
  call void @"sg_destroy_shader"(%t.sg_shader %call.arg.95.0)
  call void @"sg_shutdown"()
  ret void
}

define i32 @main() {
entry:
  call void @"kira_fn_0_main"()
  ret i32 0
}

