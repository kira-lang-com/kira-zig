; ModuleID = "main"
source_filename = "main"
target triple = "x86_64-pc-windows-msvc"

%t.app_state = type { %t.sg_shader, %t.sg_pipeline, i32, i32 }
%t.sapp_allocator = type { ptr, ptr, ptr }
%t.sapp_desc = type { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, i32, i32, i32, i32, i8, i8, i8, ptr, i8, i32, i8, i32, i32, %t.sapp_icon_desc, %t.sapp_allocator, %t.sapp_logger, %t.sapp_gl_desc, %t.sapp_win32_desc, %t.sapp_html5_desc, %t.sapp_ios_desc }
%t.sapp_event = type { i64, i32, i32, i32, i8, i32, i32, float, float, float, float, float, float, i32, [8 x %t.sapp_touchpoint], i32, i32, i32, i32 }
%t.sapp_gl_desc = type { i32, i32 }
%t.sapp_html5_desc = type { ptr, i8, i8, i8, i8, i8, i8, i8, i8, i8, i8, i8, i8 }
%t.sapp_icon_desc = type { i8, [8 x %t.sapp_image_desc] }
%t.sapp_image_desc = type { i32, i32, i32, i32, %t.sapp_range }
%t.sapp_ios_desc = type { i8 }
%t.sapp_logger = type { ptr, ptr }
%t.sapp_range = type { ptr, i64 }
%t.sapp_touchpoint = type { i64, float, float, i32, i8 }
%t.sapp_win32_desc = type { i8, i8, i8 }
%t.sg_allocator = type { ptr, ptr, ptr }
%t.sg_attachments = type { [8 x %t.sg_view], [8 x %t.sg_view], %t.sg_view }
%t.sg_blend_state = type { i8, i32, i32, i32, i32, i32, i32 }
%t.sg_color = type { float, float, float, float }
%t.sg_color_attachment_action = type { i32, i32, %t.sg_color }
%t.sg_color_target_state = type { i32, i32, %t.sg_blend_state }
%t.sg_d3d11_desc = type { i8 }
%t.sg_d3d11_environment = type { ptr, ptr }
%t.sg_d3d11_swapchain = type { ptr, ptr, ptr }
%t.sg_depth_attachment_action = type { i32, i32, float }
%t.sg_depth_state = type { i32, i32, i8, float, float, float }
%t.sg_desc = type { i32, i32, i32, i32, i32, i32, i32, i32, i32, i8, i8, %t.sg_d3d11_desc, %t.sg_metal_desc, %t.sg_wgpu_desc, %t.sg_vulkan_desc, %t.sg_allocator, %t.sg_logger, %t.sg_environment, i32 }
%t.sg_environment = type { %t.sg_environment_defaults, %t.sg_metal_environment, %t.sg_d3d11_environment, %t.sg_wgpu_environment, %t.sg_vulkan_environment }
%t.sg_environment_defaults = type { i32, i32, i32 }
%t.sg_gl_swapchain = type { i32 }
%t.sg_glsl_shader_uniform = type { i32, i16, ptr }
%t.sg_logger = type { ptr, ptr }
%t.sg_metal_desc = type { i8, i8 }
%t.sg_metal_environment = type { ptr }
%t.sg_metal_swapchain = type { ptr, ptr, ptr }
%t.sg_mtl_shader_threads_per_threadgroup = type { i32, i32, i32 }
%t.sg_pass = type { i32, i8, %t.sg_pass_action, %t.sg_attachments, %t.sg_swapchain, ptr, i32 }
%t.sg_pass_action = type { [8 x %t.sg_color_attachment_action], %t.sg_depth_attachment_action, %t.sg_stencil_attachment_action }
%t.sg_pipeline = type { i32 }
%t.sg_pipeline_desc = type { i32, i8, %t.sg_shader, %t.sg_vertex_layout_state, %t.sg_depth_state, %t.sg_stencil_state, i32, [8 x %t.sg_color_target_state], i32, i32, i32, i32, i32, %t.sg_color, i8, ptr, i32 }
%t.sg_range = type { ptr, i64 }
%t.sg_shader = type { i32 }
%t.sg_shader_desc = type { i32, %t.sg_shader_function, %t.sg_shader_function, %t.sg_shader_function, [16 x %t.sg_shader_vertex_attr], [8 x %t.sg_shader_uniform_block], [32 x %t.sg_shader_view], [12 x %t.sg_shader_sampler], [32 x %t.sg_shader_texture_sampler_pair], %t.sg_mtl_shader_threads_per_threadgroup, ptr, i32 }
%t.sg_shader_function = type { ptr, %t.sg_range, ptr, ptr, ptr }
%t.sg_shader_sampler = type { i32, i32, i8, i8, i8, i8 }
%t.sg_shader_storage_buffer_view = type { i32, i8, i8, i8, i8, i8, i8, i8 }
%t.sg_shader_storage_image_view = type { i32, i32, i32, i8, i8, i8, i8, i8, i8 }
%t.sg_shader_texture_sampler_pair = type { i32, i8, i8, ptr }
%t.sg_shader_texture_view = type { i32, i32, i32, i8, i8, i8, i8, i8 }
%t.sg_shader_uniform_block = type { i32, i32, i8, i8, i8, i8, i32, [16 x %t.sg_glsl_shader_uniform] }
%t.sg_shader_vertex_attr = type { i32, ptr, ptr, i8 }
%t.sg_shader_view = type { %t.sg_shader_texture_view, %t.sg_shader_storage_buffer_view, %t.sg_shader_storage_image_view }
%t.sg_stencil_attachment_action = type { i32, i32, i8 }
%t.sg_stencil_face_state = type { i32, i32, i32, i32 }
%t.sg_stencil_state = type { i8, %t.sg_stencil_face_state, %t.sg_stencil_face_state, i8, i8, i8 }
%t.sg_swapchain = type { i32, i32, i32, i32, i32, %t.sg_metal_swapchain, %t.sg_d3d11_swapchain, %t.sg_wgpu_swapchain, %t.sg_vulkan_swapchain, %t.sg_gl_swapchain }
%t.sg_vertex_attr_state = type { i32, i32, i32 }
%t.sg_vertex_buffer_layout_state = type { i32, i32, i32 }
%t.sg_vertex_layout_state = type { [8 x %t.sg_vertex_buffer_layout_state], [16 x %t.sg_vertex_attr_state] }
%t.sg_view = type { i32 }
%t.sg_vulkan_desc = type { i32, i32, i32 }
%t.sg_vulkan_environment = type { ptr, ptr, ptr, ptr, i32 }
%t.sg_vulkan_swapchain = type { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }
%t.sg_wgpu_desc = type { i8, i32 }
%t.sg_wgpu_environment = type { ptr }
%t.sg_wgpu_swapchain = type { ptr, ptr, ptr }

%kira.string = type { ptr, i64 }

declare void @"kira_native_print_i64"(i64)
declare void @"kira_native_print_string"(ptr, i64)
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

@kira_str_1_data = private unnamed_addr constant [386 x i8] c"#version 330\0D\0Aout vec4 color;\0D\0Aconst vec2 positions[3] = vec2[3](\0D\0A    vec2(0.0, 0.55),\0D\0A    vec2(0.55, -0.55),\0D\0A    vec2(-0.55, -0.55)\0D\0A);\0D\0Aconst vec4 colors[3] = vec4[3](\0D\0A    vec4(1.0, 0.25, 0.25, 1.0),\0D\0A    vec4(0.25, 1.0, 0.35, 1.0),\0D\0A    vec4(0.25, 0.45, 1.0, 1.0)\0D\0A);\0D\0Avoid main() {\0D\0A    gl_Position = vec4(positions[gl_VertexID], 0.0, 1.0);\0D\0A    color = colors[gl_VertexID];\0D\0A}\00"

@kira_str_1 = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([386 x i8], ptr @kira_str_1_data, i64 0, i64 0), i64 385 }

@kira_str_2_data = private unnamed_addr constant [94 x i8] c"#version 330\0D\0Ain vec4 color;\0D\0Aout vec4 frag_color;\0D\0Avoid main() {\0D\0A    frag_color = color;\0D\0A}\00"

@kira_str_2 = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([94 x i8], ptr @kira_str_2_data, i64 0, i64 0), i64 93 }


define void @"kira_fn_0_main"() {
entry:
  %local0 = alloca %t.app_state
  store %t.app_state zeroinitializer, ptr %local0
  %local1 = alloca %t.sapp_desc
  store %t.sapp_desc zeroinitializer, ptr %local1
  %r0 = add i64 0, 128
  %r1 = ptrtoint ptr %local0 to i64
  %field.base.2 = inttoptr i64 %r1 to ptr
  %field.ptr.2 = getelementptr inbounds %t.app_state, ptr %field.base.2, i32 0, i32 2
  %r2 = ptrtoint ptr %field.ptr.2 to i64
  %store.ptr.0 = inttoptr i64 %r2 to ptr
  %store.cast.0 = trunc i64 %r0 to i32
  store i32 %store.cast.0, ptr %store.ptr.0
  %r3 = add i64 0, 128
  %r4 = ptrtoint ptr %local0 to i64
  %field.base.5 = inttoptr i64 %r4 to ptr
  %field.ptr.5 = getelementptr inbounds %t.app_state, ptr %field.base.5, i32 0, i32 3
  %r5 = ptrtoint ptr %field.ptr.5 to i64
  %store.ptr.3 = inttoptr i64 %r5 to ptr
  %store.cast.3 = trunc i64 %r3 to i32
  store i32 %store.cast.3, ptr %store.ptr.3
  %r6 = ptrtoint ptr @"kira_fn_1_init" to i64
  %r7 = ptrtoint ptr %local1 to i64
  %field.base.8 = inttoptr i64 %r7 to ptr
  %field.ptr.8 = getelementptr inbounds %t.sapp_desc, ptr %field.base.8, i32 0, i32 5
  %r8 = ptrtoint ptr %field.ptr.8 to i64
  %store.ptr.6 = inttoptr i64 %r8 to ptr
  %store.rawptr.6 = inttoptr i64 %r6 to ptr
  store ptr %store.rawptr.6, ptr %store.ptr.6
  %r9 = ptrtoint ptr @"kira_fn_2_frame" to i64
  %r10 = ptrtoint ptr %local1 to i64
  %field.base.11 = inttoptr i64 %r10 to ptr
  %field.ptr.11 = getelementptr inbounds %t.sapp_desc, ptr %field.base.11, i32 0, i32 6
  %r11 = ptrtoint ptr %field.ptr.11 to i64
  %store.ptr.9 = inttoptr i64 %r11 to ptr
  %store.rawptr.9 = inttoptr i64 %r9 to ptr
  store ptr %store.rawptr.9, ptr %store.ptr.9
  %r12 = ptrtoint ptr @"kira_fn_4_cleanup" to i64
  %r13 = ptrtoint ptr %local1 to i64
  %field.base.14 = inttoptr i64 %r13 to ptr
  %field.ptr.14 = getelementptr inbounds %t.sapp_desc, ptr %field.base.14, i32 0, i32 7
  %r14 = ptrtoint ptr %field.ptr.14 to i64
  %store.ptr.12 = inttoptr i64 %r14 to ptr
  %store.rawptr.12 = inttoptr i64 %r12 to ptr
  store ptr %store.rawptr.12, ptr %store.ptr.12
  %r15 = ptrtoint ptr @"kira_fn_3_event" to i64
  %r16 = ptrtoint ptr %local1 to i64
  %field.base.17 = inttoptr i64 %r16 to ptr
  %field.ptr.17 = getelementptr inbounds %t.sapp_desc, ptr %field.base.17, i32 0, i32 8
  %r17 = ptrtoint ptr %field.ptr.17 to i64
  %store.ptr.15 = inttoptr i64 %r17 to ptr
  %store.rawptr.15 = inttoptr i64 %r15 to ptr
  store ptr %store.rawptr.15, ptr %store.ptr.15
  %r18 = ptrtoint ptr %local0 to i64
  %r19 = ptrtoint ptr %local1 to i64
  %field.base.20 = inttoptr i64 %r19 to ptr
  %field.ptr.20 = getelementptr inbounds %t.sapp_desc, ptr %field.base.20, i32 0, i32 4
  %r20 = ptrtoint ptr %field.ptr.20 to i64
  %store.ptr.18 = inttoptr i64 %r20 to ptr
  %store.rawptr.18 = inttoptr i64 %r18 to ptr
  store ptr %store.rawptr.18, ptr %store.ptr.18
  %r21 = add i64 0, 640
  %r22 = ptrtoint ptr %local1 to i64
  %field.base.23 = inttoptr i64 %r22 to ptr
  %field.ptr.23 = getelementptr inbounds %t.sapp_desc, ptr %field.base.23, i32 0, i32 9
  %r23 = ptrtoint ptr %field.ptr.23 to i64
  %store.ptr.21 = inttoptr i64 %r23 to ptr
  %store.cast.21 = trunc i64 %r21 to i32
  store i32 %store.cast.21, ptr %store.ptr.21
  %r24 = add i64 0, 480
  %r25 = ptrtoint ptr %local1 to i64
  %field.base.26 = inttoptr i64 %r25 to ptr
  %field.ptr.26 = getelementptr inbounds %t.sapp_desc, ptr %field.base.26, i32 0, i32 10
  %r26 = ptrtoint ptr %field.ptr.26 to i64
  %store.ptr.24 = inttoptr i64 %r26 to ptr
  %store.cast.24 = trunc i64 %r24 to i32
  store i32 %store.cast.24, ptr %store.ptr.24
  %r27 = load %kira.string, ptr @kira_str_0
  %r28 = ptrtoint ptr %local1 to i64
  %field.base.29 = inttoptr i64 %r28 to ptr
  %field.ptr.29 = getelementptr inbounds %t.sapp_desc, ptr %field.base.29, i32 0, i32 16
  %r29 = ptrtoint ptr %field.ptr.29 to i64
  %store.ptr.27 = inttoptr i64 %r29 to ptr
  %store.cstr.27 = extractvalue %kira.string %r27, 0
  store ptr %store.cstr.27, ptr %store.ptr.27
  %r30 = ptrtoint ptr %local1 to i64
  %call.arg.44.0 = inttoptr i64 %r30 to ptr
  call void @"sapp_run"(ptr %call.arg.44.0)
  ret void
}

define void @"kira_fn_1_init"(i64 %arg0) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  %local2 = alloca %t.sg_desc
  store %t.sg_desc zeroinitializer, ptr %local2
  %local3 = alloca %t.sg_shader_desc
  store %t.sg_shader_desc zeroinitializer, ptr %local3
  %local4 = alloca %t.sg_pipeline_desc
  store %t.sg_pipeline_desc zeroinitializer, ptr %local4
  store i64 %arg0, ptr %local0
  %r0 = load i64, ptr %local0
  store i64 %r0, ptr %local1
  %call.int.1 = call i32 @"sapp_width"()
  %r1.sext = sext i32 %call.int.1 to i64
  %r1 = add i64 %r1.sext, 0
  %r2 = load i64, ptr %local1
  %field.base.3 = inttoptr i64 %r2 to ptr
  %field.ptr.3 = getelementptr inbounds %t.app_state, ptr %field.base.3, i32 0, i32 2
  %r3 = ptrtoint ptr %field.ptr.3 to i64
  %store.ptr.1 = inttoptr i64 %r3 to ptr
  %store.cast.1 = trunc i64 %r1 to i32
  store i32 %store.cast.1, ptr %store.ptr.1
  %call.int.4 = call i32 @"sapp_height"()
  %r4.sext = sext i32 %call.int.4 to i64
  %r4 = add i64 %r4.sext, 0
  %r5 = load i64, ptr %local1
  %field.base.6 = inttoptr i64 %r5 to ptr
  %field.ptr.6 = getelementptr inbounds %t.app_state, ptr %field.base.6, i32 0, i32 3
  %r6 = ptrtoint ptr %field.ptr.6 to i64
  %store.ptr.4 = inttoptr i64 %r6 to ptr
  %store.cast.4 = trunc i64 %r4 to i32
  store i32 %store.cast.4, ptr %store.ptr.4
  %call.struct.7 = call %t.sg_environment @"sglue_environment"()
  %call.ret.ptr.7 = alloca %t.sg_environment
  store %t.sg_environment %call.struct.7, ptr %call.ret.ptr.7
  %r7 = ptrtoint ptr %call.ret.ptr.7 to i64
  %r8 = ptrtoint ptr %local2 to i64
  %field.base.9 = inttoptr i64 %r8 to ptr
  %field.ptr.9 = getelementptr inbounds %t.sg_desc, ptr %field.base.9, i32 0, i32 17
  %r9 = ptrtoint ptr %field.ptr.9 to i64
  %copy.dst.9 = inttoptr i64 %r9 to ptr
  %copy.src.7 = inttoptr i64 %r7 to ptr
  %copy.val.9 = load %t.sg_environment, ptr %copy.src.7
  store %t.sg_environment %copy.val.9, ptr %copy.dst.9
  %r10 = ptrtoint ptr %local2 to i64
  %call.arg.188.0 = inttoptr i64 %r10 to ptr
  call void @"sg_setup"(ptr %call.arg.188.0)
  %r11 = load %kira.string, ptr @kira_str_1
  %r12 = ptrtoint ptr %local3 to i64
  %field.base.13 = inttoptr i64 %r12 to ptr
  %field.ptr.13 = getelementptr inbounds %t.sg_shader_desc, ptr %field.base.13, i32 0, i32 1
  %r13 = ptrtoint ptr %field.ptr.13 to i64
  %field.base.14 = inttoptr i64 %r13 to ptr
  %field.ptr.14 = getelementptr inbounds %t.sg_shader_function, ptr %field.base.14, i32 0, i32 0
  %r14 = ptrtoint ptr %field.ptr.14 to i64
  %store.ptr.11 = inttoptr i64 %r14 to ptr
  %store.cstr.11 = extractvalue %kira.string %r11, 0
  store ptr %store.cstr.11, ptr %store.ptr.11
  %r15 = load %kira.string, ptr @kira_str_2
  %r16 = ptrtoint ptr %local3 to i64
  %field.base.17 = inttoptr i64 %r16 to ptr
  %field.ptr.17 = getelementptr inbounds %t.sg_shader_desc, ptr %field.base.17, i32 0, i32 2
  %r17 = ptrtoint ptr %field.ptr.17 to i64
  %field.base.18 = inttoptr i64 %r17 to ptr
  %field.ptr.18 = getelementptr inbounds %t.sg_shader_function, ptr %field.base.18, i32 0, i32 0
  %r18 = ptrtoint ptr %field.ptr.18 to i64
  %store.ptr.15 = inttoptr i64 %r18 to ptr
  %store.cstr.15 = extractvalue %kira.string %r15, 0
  store ptr %store.cstr.15, ptr %store.ptr.15
  %r19 = ptrtoint ptr %local3 to i64
  %call.arg.126.0 = inttoptr i64 %r19 to ptr
  %call.struct.20 = call %t.sg_shader @"sg_make_shader"(ptr %call.arg.126.0)
  %call.ret.ptr.20 = alloca %t.sg_shader
  store %t.sg_shader %call.struct.20, ptr %call.ret.ptr.20
  %r20 = ptrtoint ptr %call.ret.ptr.20 to i64
  %r21 = load i64, ptr %local1
  %field.base.22 = inttoptr i64 %r21 to ptr
  %field.ptr.22 = getelementptr inbounds %t.app_state, ptr %field.base.22, i32 0, i32 0
  %r22 = ptrtoint ptr %field.ptr.22 to i64
  %copy.dst.22 = inttoptr i64 %r22 to ptr
  %copy.src.20 = inttoptr i64 %r20 to ptr
  %copy.val.22 = load %t.sg_shader, ptr %copy.src.20
  store %t.sg_shader %copy.val.22, ptr %copy.dst.22
  %r23 = load i64, ptr %local1
  %field.base.24 = inttoptr i64 %r23 to ptr
  %field.ptr.24 = getelementptr inbounds %t.app_state, ptr %field.base.24, i32 0, i32 0
  %r24 = ptrtoint ptr %field.ptr.24 to i64
  %r25 = ptrtoint ptr %local4 to i64
  %field.base.26 = inttoptr i64 %r25 to ptr
  %field.ptr.26 = getelementptr inbounds %t.sg_pipeline_desc, ptr %field.base.26, i32 0, i32 2
  %r26 = ptrtoint ptr %field.ptr.26 to i64
  %copy.dst.26 = inttoptr i64 %r26 to ptr
  %copy.src.24 = inttoptr i64 %r24 to ptr
  %copy.val.26 = load %t.sg_shader, ptr %copy.src.24
  store %t.sg_shader %copy.val.26, ptr %copy.dst.26
  %r27 = ptrtoint ptr %local4 to i64
  %call.arg.124.0 = inttoptr i64 %r27 to ptr
  %call.struct.28 = call %t.sg_pipeline @"sg_make_pipeline"(ptr %call.arg.124.0)
  %call.ret.ptr.28 = alloca %t.sg_pipeline
  store %t.sg_pipeline %call.struct.28, ptr %call.ret.ptr.28
  %r28 = ptrtoint ptr %call.ret.ptr.28 to i64
  %r29 = load i64, ptr %local1
  %field.base.30 = inttoptr i64 %r29 to ptr
  %field.ptr.30 = getelementptr inbounds %t.app_state, ptr %field.base.30, i32 0, i32 1
  %r30 = ptrtoint ptr %field.ptr.30 to i64
  %copy.dst.30 = inttoptr i64 %r30 to ptr
  %copy.src.28 = inttoptr i64 %r28 to ptr
  %copy.val.30 = load %t.sg_pipeline, ptr %copy.src.28
  store %t.sg_pipeline %copy.val.30, ptr %copy.dst.30
  ret void
}

define void @"kira_fn_2_frame"(i64 %arg0) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  %local2 = alloca %t.sg_pass
  store %t.sg_pass zeroinitializer, ptr %local2
  store i64 %arg0, ptr %local0
  %r0 = load i64, ptr %local0
  store i64 %r0, ptr %local1
  %call.int.1 = call i32 @"sapp_width"()
  %r1.sext = sext i32 %call.int.1 to i64
  %r1 = add i64 %r1.sext, 0
  %r2 = load i64, ptr %local1
  %field.base.3 = inttoptr i64 %r2 to ptr
  %field.ptr.3 = getelementptr inbounds %t.app_state, ptr %field.base.3, i32 0, i32 2
  %r3 = ptrtoint ptr %field.ptr.3 to i64
  %store.ptr.1 = inttoptr i64 %r3 to ptr
  %store.cast.1 = trunc i64 %r1 to i32
  store i32 %store.cast.1, ptr %store.ptr.1
  %call.int.4 = call i32 @"sapp_height"()
  %r4.sext = sext i32 %call.int.4 to i64
  %r4 = add i64 %r4.sext, 0
  %r5 = load i64, ptr %local1
  %field.base.6 = inttoptr i64 %r5 to ptr
  %field.ptr.6 = getelementptr inbounds %t.app_state, ptr %field.base.6, i32 0, i32 3
  %r6 = ptrtoint ptr %field.ptr.6 to i64
  %store.ptr.4 = inttoptr i64 %r6 to ptr
  %store.cast.4 = trunc i64 %r4 to i32
  store i32 %store.cast.4, ptr %store.ptr.4
  %call.struct.7 = call %t.sg_swapchain @"sglue_swapchain"()
  %call.ret.ptr.7 = alloca %t.sg_swapchain
  store %t.sg_swapchain %call.struct.7, ptr %call.ret.ptr.7
  %r7 = ptrtoint ptr %call.ret.ptr.7 to i64
  %r8 = ptrtoint ptr %local2 to i64
  %field.base.9 = inttoptr i64 %r8 to ptr
  %field.ptr.9 = getelementptr inbounds %t.sg_pass, ptr %field.base.9, i32 0, i32 4
  %r9 = ptrtoint ptr %field.ptr.9 to i64
  %copy.dst.9 = inttoptr i64 %r9 to ptr
  %copy.src.7 = inttoptr i64 %r7 to ptr
  %copy.val.9 = load %t.sg_swapchain, ptr %copy.src.7
  store %t.sg_swapchain %copy.val.9, ptr %copy.dst.9
  %r10 = ptrtoint ptr %local2 to i64
  %call.arg.75.0 = inttoptr i64 %r10 to ptr
  call void @"sg_begin_pass"(ptr %call.arg.75.0)
  %r11 = add i64 0, 0
  %r12 = add i64 0, 0
  %r13 = load i64, ptr %local1
  %field.base.14 = inttoptr i64 %r13 to ptr
  %field.ptr.14 = getelementptr inbounds %t.app_state, ptr %field.base.14, i32 0, i32 2
  %r14 = ptrtoint ptr %field.ptr.14 to i64
  %load.ptr.15 = inttoptr i64 %r14 to ptr
  %load.raw.15 = load i32, ptr %load.ptr.15
  %r15 = sext i32 %load.raw.15 to i64
  %r16 = load i64, ptr %local1
  %field.base.17 = inttoptr i64 %r16 to ptr
  %field.ptr.17 = getelementptr inbounds %t.app_state, ptr %field.base.17, i32 0, i32 3
  %r17 = ptrtoint ptr %field.ptr.17 to i64
  %load.ptr.18 = inttoptr i64 %r17 to ptr
  %load.raw.18 = load i32, ptr %load.ptr.18
  %r18 = sext i32 %load.raw.18 to i64
  %r19 = add i1 0, 1
  %call.arg.73.0 = trunc i64 %r11 to i32
  %call.arg.73.1 = trunc i64 %r12 to i32
  %call.arg.73.2 = trunc i64 %r15 to i32
  %call.arg.73.3 = trunc i64 %r18 to i32
  call void @"sg_apply_viewport"(i32 %call.arg.73.0, i32 %call.arg.73.1, i32 %call.arg.73.2, i32 %call.arg.73.3, i1 %r19)
  %r20 = load i64, ptr %local1
  %field.base.21 = inttoptr i64 %r20 to ptr
  %field.ptr.21 = getelementptr inbounds %t.app_state, ptr %field.base.21, i32 0, i32 1
  %r21 = ptrtoint ptr %field.ptr.21 to i64
  %call.arg.ptr.69.0 = inttoptr i64 %r21 to ptr
  %call.arg.69.0 = load %t.sg_pipeline, ptr %call.arg.ptr.69.0
  call void @"sg_apply_pipeline"(%t.sg_pipeline %call.arg.69.0)
  %r22 = add i64 0, 0
  %r23 = add i64 0, 3
  %r24 = add i64 0, 1
  %call.arg.99.0 = trunc i64 %r22 to i32
  %call.arg.99.1 = trunc i64 %r23 to i32
  %call.arg.99.2 = trunc i64 %r24 to i32
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
  store i64 %r0, ptr %local2
  %r1 = load i64, ptr %local0
  %field.base.2 = inttoptr i64 %r1 to ptr
  %field.ptr.2 = getelementptr inbounds %t.sapp_event, ptr %field.base.2, i32 0, i32 17
  %r2 = ptrtoint ptr %field.ptr.2 to i64
  %load.ptr.3 = inttoptr i64 %r2 to ptr
  %load.raw.3 = load i32, ptr %load.ptr.3
  %r3 = sext i32 %load.raw.3 to i64
  %r4 = load i64, ptr %local2
  %field.base.5 = inttoptr i64 %r4 to ptr
  %field.ptr.5 = getelementptr inbounds %t.app_state, ptr %field.base.5, i32 0, i32 2
  %r5 = ptrtoint ptr %field.ptr.5 to i64
  %store.ptr.3 = inttoptr i64 %r5 to ptr
  %store.cast.3 = trunc i64 %r3 to i32
  store i32 %store.cast.3, ptr %store.ptr.3
  %r6 = load i64, ptr %local0
  %field.base.7 = inttoptr i64 %r6 to ptr
  %field.ptr.7 = getelementptr inbounds %t.sapp_event, ptr %field.base.7, i32 0, i32 18
  %r7 = ptrtoint ptr %field.ptr.7 to i64
  %load.ptr.8 = inttoptr i64 %r7 to ptr
  %load.raw.8 = load i32, ptr %load.ptr.8
  %r8 = sext i32 %load.raw.8 to i64
  %r9 = load i64, ptr %local2
  %field.base.10 = inttoptr i64 %r9 to ptr
  %field.ptr.10 = getelementptr inbounds %t.app_state, ptr %field.base.10, i32 0, i32 3
  %r10 = ptrtoint ptr %field.ptr.10 to i64
  %store.ptr.8 = inttoptr i64 %r10 to ptr
  %store.cast.8 = trunc i64 %r8 to i32
  store i32 %store.cast.8, ptr %store.ptr.8
  ret void
}

define void @"kira_fn_4_cleanup"(i64 %arg0) {
entry:
  %local0 = alloca i64
  %local1 = alloca i64
  store i64 %arg0, ptr %local0
  %r0 = load i64, ptr %local0
  store i64 %r0, ptr %local1
  %r1 = load i64, ptr %local1
  %field.base.2 = inttoptr i64 %r1 to ptr
  %field.ptr.2 = getelementptr inbounds %t.app_state, ptr %field.base.2, i32 0, i32 1
  %r2 = ptrtoint ptr %field.ptr.2 to i64
  %call.arg.ptr.93.0 = inttoptr i64 %r2 to ptr
  %call.arg.93.0 = load %t.sg_pipeline, ptr %call.arg.ptr.93.0
  call void @"sg_destroy_pipeline"(%t.sg_pipeline %call.arg.93.0)
  %r3 = load i64, ptr %local1
  %field.base.4 = inttoptr i64 %r3 to ptr
  %field.ptr.4 = getelementptr inbounds %t.app_state, ptr %field.base.4, i32 0, i32 0
  %r4 = ptrtoint ptr %field.ptr.4 to i64
  %call.arg.ptr.95.0 = inttoptr i64 %r4 to ptr
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

