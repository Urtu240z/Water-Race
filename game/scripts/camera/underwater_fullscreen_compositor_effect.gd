@tool
class_name UnderwaterFullscreenCompositorEffect
extends CompositorEffect

const COMPUTE_SHADER_PATH: String = (
	"res://shaders/effects/underwater_fullscreen_compositor.glsl"
)
const COPY_SHADER_SOURCE: String = """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform writeonly image2D output_image;
layout(rgba16f, set = 0, binding = 1) uniform readonly image2D source_image;
layout(set = 0, binding = 3, std430) readonly buffer EffectParameters {
	vec4 values[11];
} parameters;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(parameters.values[0].xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	imageStore(output_image, pixel, imageLoad(source_image, pixel));
}
"""
const GAUSSIAN_BLUR_SHADER_TEMPLATE: String = """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform writeonly image2D output_image;
layout(set = 0, binding = 1) uniform sampler2D source_texture;
layout(set = 0, binding = 3, std430) readonly buffer EffectParameters {
	vec4 values[11];
} parameters;

const vec2 BLUR_DIRECTION = #DIRECTION#;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(parameters.values[0].xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	vec2 texture_size = vec2(size);
	vec2 uv = (vec2(pixel) + vec2(0.5)) / texture_size;
	float effect_strength = clamp(parameters.values[0].z, 0.0, 1.0);
	int transition_mode = int(round(parameters.values[4].w));
	float transition_progress = clamp(parameters.values[9].x, 0.0, 1.0);
	float transition_strength = max(parameters.values[9].y, 0.0);
	float exit_blur_strength = transition_mode == 2
		? (1.0 - smoothstep(0.0, 1.0, transition_progress))
			* transition_strength
		: 0.0;
	float active_blur_strength = max(
		effect_strength,
		exit_blur_strength
	);
	float blur_radius = max(parameters.values[0].w, 0.0)
		* active_blur_strength;
	float pass_count = max(parameters.values[4].z, 1.0);
	float sample_scale = blur_radius / (3.2307692308 * sqrt(pass_count));
	vec2 sample_offset = BLUR_DIRECTION * sample_scale / texture_size;

	vec4 color = texture(source_texture, uv) * 0.2270270270;
	color += texture(
		source_texture,
		clamp(uv + sample_offset * 1.3846153846, vec2(0.0), vec2(1.0))
	) * 0.3162162162;
	color += texture(
		source_texture,
		clamp(uv - sample_offset * 1.3846153846, vec2(0.0), vec2(1.0))
	) * 0.3162162162;
	color += texture(
		source_texture,
		clamp(uv + sample_offset * 3.2307692308, vec2(0.0), vec2(1.0))
	) * 0.0702702703;
	color += texture(
		source_texture,
		clamp(uv - sample_offset * 3.2307692308, vec2(0.0), vec2(1.0))
	) * 0.0702702703;
	imageStore(output_image, pixel, color);
}
"""
const PARAMETER_FLOAT_COUNT: int = 44
const THREAD_GROUP_SIZE: int = 8
const TEXTURE_CONTEXT: StringName = &"underwater_fullscreen"
const SOURCE_TEXTURE_NAME: StringName = &"source_color"
const BLUR_TEXTURE_NAME: StringName = &"blur_color"

var _rendering_device: RenderingDevice
var _copy_shader: RID
var _copy_pipeline: RID
var _horizontal_blur_shader: RID
var _horizontal_blur_pipeline: RID
var _vertical_blur_shader: RID
var _vertical_blur_pipeline: RID
var _shader: RID
var _pipeline: RID
var _depth_sampler: RID
var _color_sampler: RID
var _parameter_buffer: RID
var _parameter_mutex: Mutex = Mutex.new()
var _runtime_mutex: Mutex = Mutex.new()
var _resource_initialization_attempted := false
var _resource_initialization_failed := false
var _resources_ready := false
var _failure_reported := false
var _last_error := ""
var _render_callback_count := 0
var _successful_render_count := 0
var _last_render_size := Vector2i.ZERO
var _effect_strength: float = 0.0
var _blur_strength: float = 0.0
var _blur_passes: int = 2
var _transition_mode: int = 0
var _transition_progress: float = 1.0
var _transition_strength: float = 1.0
var _wet_lens_texture_rid: RID
var _wet_lens_zoom: float = 1.0
var _wet_lens_warp_strength: float = 1.0
var _wet_lens_fall_distance: float = 0.28
var _wet_lens_wash_irregularity: float = 1.0
var _wet_lens_wash_softness: float = 0.18
var _wet_lens_texture_edge_feather: float = 0.08
var _underwater_tint: Color = Color(0.10, 0.40, 0.50, 1.0)
var _fog_tint: Color = Color(0.10, 0.40, 0.50, 1.0)
var _tint_strength: float = 0.16
var _contrast: float = 0.94
var _fog_density: float = 0.009
var _fog_start_distance: float = 5.0
var _visibility_radius: float = 80.0
var _visibility_blend: float = 20.0
var _compute_shader_source: String = ""


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	_rendering_device = RenderingServer.get_rendering_device()
	_compute_shader_source = FileAccess.get_file_as_string(
		COMPUTE_SHADER_PATH
	).trim_prefix("#[compute]\n")


func update_parameters(
	effect_strength: float,
	blur_strength: float,
	blur_passes: int,
	transition_mode: int,
	transition_progress: float,
	transition_strength: float,
	wet_lens_height_texture: Texture2D,
	wet_lens_zoom: float,
	wet_lens_warp_strength: float,
	wet_lens_fall_distance: float,
	wet_lens_wash_irregularity: float,
	wet_lens_wash_softness: float,
	wet_lens_texture_edge_feather: float,
	underwater_tint: Color,
	fog_tint: Color,
	tint_strength: float,
	contrast: float,
	fog_density: float,
	fog_start_distance: float,
	visibility_radius: float,
	visibility_blend: float
) -> void:
	_parameter_mutex.lock()
	_effect_strength = effect_strength
	_blur_strength = blur_strength
	_blur_passes = clampi(blur_passes, 1, 4)
	_transition_mode = clampi(transition_mode, 0, 2)
	_transition_progress = clampf(transition_progress, 0.0, 1.0)
	_transition_strength = maxf(transition_strength, 0.0)
	_wet_lens_texture_rid = (
		wet_lens_height_texture.get_rid()
		if wet_lens_height_texture != null
		else RID()
	)
	_wet_lens_zoom = maxf(wet_lens_zoom, 0.01)
	_wet_lens_warp_strength = maxf(wet_lens_warp_strength, 0.0)
	_wet_lens_fall_distance = maxf(wet_lens_fall_distance, 0.0)
	_wet_lens_wash_irregularity = maxf(
		wet_lens_wash_irregularity,
		0.0
	)
	_wet_lens_wash_softness = maxf(wet_lens_wash_softness, 0.001)
	_wet_lens_texture_edge_feather = maxf(
		wet_lens_texture_edge_feather,
		0.0
	)
	_underwater_tint = underwater_tint
	_fog_tint = fog_tint
	_tint_strength = tint_strength
	_contrast = contrast
	_fog_density = fog_density
	_fog_start_distance = fog_start_distance
	_visibility_radius = visibility_radius
	_visibility_blend = visibility_blend
	_parameter_mutex.unlock()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rendering_device == null:
		return
	for resource_rid in [
		_copy_pipeline,
		_horizontal_blur_pipeline,
		_vertical_blur_pipeline,
		_pipeline,
		_copy_shader,
		_horizontal_blur_shader,
		_vertical_blur_shader,
		_shader,
		_depth_sampler,
		_color_sampler,
		_parameter_buffer,
	]:
		if resource_rid.is_valid():
			_rendering_device.free_rid(resource_rid)


## Builds and validates the compute route without enabling a visual pass.
## Godot compositor effects commonly create RenderingDevice resources from the
## main thread; keeping this explicit lets the controller select its fallback
## before the first underwater frame.
func initialize_compute_resources() -> bool:
	return _ensure_compute_resources()


func _ensure_compute_resources() -> bool:
	if _rendering_device == null:
		_rendering_device = RenderingServer.get_rendering_device()
	if _rendering_device == null:
		_set_runtime_failure("RenderingDevice is unavailable.", false)
		return false

	_runtime_mutex.lock()
	var initialization_failed := _resource_initialization_failed
	_resource_initialization_attempted = true
	_runtime_mutex.unlock()
	if initialization_failed:
		return false
	if _pipeline.is_valid():
		_mark_resources_ready()
		return true
	if _compute_shader_source.is_empty():
		_compute_shader_source = FileAccess.get_file_as_string(
			COMPUTE_SHADER_PATH
		).trim_prefix("#[compute]\n")
	if _compute_shader_source.is_empty():
		_set_runtime_failure(
			"The underwater compositor GLSL source could not be loaded."
		)
		return false

	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = _compute_shader_source
	var shader_spirv := (
		_rendering_device.shader_compile_spirv_from_source(shader_source)
	)
	if not shader_spirv.compile_error_compute.is_empty():
		_set_runtime_failure(
			"Underwater fullscreen compositor shader compile failed: %s"
			% shader_spirv.compile_error_compute
		)
		return false
	_shader = _rendering_device.shader_create_from_spirv(shader_spirv)
	if not _shader.is_valid():
		_set_runtime_failure(
			"Underwater fullscreen compositor shader RID is invalid."
		)
		return false
	_pipeline = _rendering_device.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_set_runtime_failure(
			"Underwater fullscreen compositor pipeline is invalid."
		)
		return false

	var copy_shader_source := RDShaderSource.new()
	copy_shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	copy_shader_source.source_compute = COPY_SHADER_SOURCE
	var copy_shader_spirv := (
		_rendering_device.shader_compile_spirv_from_source(copy_shader_source)
	)
	if not copy_shader_spirv.compile_error_compute.is_empty():
		_set_runtime_failure(
			"Underwater fullscreen copy shader compile failed: %s"
			% copy_shader_spirv.compile_error_compute
		)
		return false
	_copy_shader = _rendering_device.shader_create_from_spirv(
		copy_shader_spirv
	)
	if not _copy_shader.is_valid():
		_set_runtime_failure(
			"Underwater fullscreen copy shader RID is invalid."
		)
		return false
	_copy_pipeline = _rendering_device.compute_pipeline_create(_copy_shader)
	if not _copy_pipeline.is_valid():
		_set_runtime_failure(
			"Underwater fullscreen copy pipeline is invalid."
		)
		return false

	var horizontal_source := RDShaderSource.new()
	horizontal_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	horizontal_source.source_compute = GAUSSIAN_BLUR_SHADER_TEMPLATE.replace(
		"#DIRECTION#",
		"vec2(1.0, 0.0)"
	)
	var horizontal_spirv := (
		_rendering_device.shader_compile_spirv_from_source(horizontal_source)
	)
	if not horizontal_spirv.compile_error_compute.is_empty():
		_set_runtime_failure(
			"Underwater horizontal blur shader compile failed: %s"
			% horizontal_spirv.compile_error_compute
		)
		return false
	_horizontal_blur_shader = _rendering_device.shader_create_from_spirv(
		horizontal_spirv
	)
	if not _horizontal_blur_shader.is_valid():
		_set_runtime_failure(
			"Underwater horizontal blur shader RID is invalid."
		)
		return false
	_horizontal_blur_pipeline = _rendering_device.compute_pipeline_create(
		_horizontal_blur_shader
	)
	if not _horizontal_blur_pipeline.is_valid():
		_set_runtime_failure(
			"Underwater horizontal blur pipeline is invalid."
		)
		return false

	var vertical_source := RDShaderSource.new()
	vertical_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	vertical_source.source_compute = GAUSSIAN_BLUR_SHADER_TEMPLATE.replace(
		"#DIRECTION#",
		"vec2(0.0, 1.0)"
	)
	var vertical_spirv := (
		_rendering_device.shader_compile_spirv_from_source(vertical_source)
	)
	if not vertical_spirv.compile_error_compute.is_empty():
		_set_runtime_failure(
			"Underwater vertical blur shader compile failed: %s"
			% vertical_spirv.compile_error_compute
		)
		return false
	_vertical_blur_shader = _rendering_device.shader_create_from_spirv(
		vertical_spirv
	)
	if not _vertical_blur_shader.is_valid():
		_set_runtime_failure(
			"Underwater vertical blur shader RID is invalid."
		)
		return false
	_vertical_blur_pipeline = _rendering_device.compute_pipeline_create(
		_vertical_blur_shader
	)
	if not _vertical_blur_pipeline.is_valid():
		_set_runtime_failure(
			"Underwater vertical blur pipeline is invalid."
		)
		return false

	var depth_sampler_state := RDSamplerState.new()
	depth_sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	depth_sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	depth_sampler_state.repeat_u = (
		RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	)
	depth_sampler_state.repeat_v = (
		RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	)
	_depth_sampler = _rendering_device.sampler_create(depth_sampler_state)
	var color_sampler_state := RDSamplerState.new()
	color_sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	color_sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	color_sampler_state.repeat_u = (
		RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	)
	color_sampler_state.repeat_v = (
		RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	)
	_color_sampler = _rendering_device.sampler_create(color_sampler_state)
	_parameter_buffer = _rendering_device.storage_buffer_create(
		PARAMETER_FLOAT_COUNT * 4
	)
	var resources_valid := (
		_depth_sampler.is_valid()
		and _color_sampler.is_valid()
		and _parameter_buffer.is_valid()
	)
	if not resources_valid:
		_set_runtime_failure(
			"One or more underwater compositor compute resources are invalid."
		)
		return false
	_mark_resources_ready()
	return true


func _set_runtime_failure(message: String, report_error: bool = true) -> void:
	_runtime_mutex.lock()
	_resource_initialization_attempted = true
	_resource_initialization_failed = true
	_resources_ready = false
	_last_error = message
	var should_report := not _failure_reported
	_failure_reported = true
	_runtime_mutex.unlock()
	if should_report and report_error:
		push_error(message)


func _mark_resources_ready() -> void:
	_runtime_mutex.lock()
	_resources_ready = true
	_resource_initialization_failed = false
	_last_error = ""
	_runtime_mutex.unlock()


func get_runtime_debug_status() -> Dictionary:
	_runtime_mutex.lock()
	var status := {
		"rendering_device_valid": _rendering_device != null,
		"resource_initialization_attempted":
			_resource_initialization_attempted,
		"resource_initialization_failed": _resource_initialization_failed,
		"resources_ready": _resources_ready,
		"last_error": _last_error,
		"render_callback_count": _render_callback_count,
		"successful_render_count": _successful_render_count,
		"last_render_size": _last_render_size,
	}
	_runtime_mutex.unlock()
	if _rendering_device != null:
		status.merge(
			{
				"shader_valid": _shader.is_valid(),
				"pipeline_valid": _pipeline.is_valid(),
				"copy_pipeline_valid": _copy_pipeline.is_valid(),
				"horizontal_blur_pipeline_valid":
					_horizontal_blur_pipeline.is_valid(),
				"vertical_blur_pipeline_valid":
					_vertical_blur_pipeline.is_valid(),
				"parameter_buffer_valid": _parameter_buffer.is_valid(),
				"depth_sampler_valid": _depth_sampler.is_valid(),
				"color_sampler_valid": _color_sampler.is_valid(),
			},
			true
		)
	return status


func _render_callback(
	callback_type: int,
	render_data: RenderData
) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	_runtime_mutex.lock()
	_render_callback_count += 1
	_runtime_mutex.unlock()
	if not _ensure_compute_resources():
		return

	var render_buffers := (
		render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	)
	var scene_data := render_data.get_render_scene_data()
	if render_buffers == null or scene_data == null:
		return
	var render_size := render_buffers.get_internal_size()
	if render_size.x <= 0 or render_size.y <= 0:
		return

	var temporary_texture_names: Array[StringName] = [
		SOURCE_TEXTURE_NAME,
		BLUR_TEXTURE_NAME,
	]
	for texture_name in temporary_texture_names:
		if render_buffers.has_texture(TEXTURE_CONTEXT, texture_name):
			continue
		var usage_bits := (
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		)
		render_buffers.create_texture(
			TEXTURE_CONTEXT,
			texture_name,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			usage_bits,
			RenderingDevice.TEXTURE_SAMPLES_1,
			render_size,
			render_buffers.get_view_count(),
			1,
			false,
			false
		)

	var group_count_x := ceili(float(render_size.x) / THREAD_GROUP_SIZE)
	var group_count_y := ceili(float(render_size.y) / THREAD_GROUP_SIZE)
	var rendered_any := false
	for view_index in render_buffers.get_view_count():
		var output_image := render_buffers.get_color_layer(view_index)
		var source_image := render_buffers.get_texture_slice(
			TEXTURE_CONTEXT,
			SOURCE_TEXTURE_NAME,
			view_index,
			0,
			1,
			1
		)
		var blur_image := render_buffers.get_texture_slice(
			TEXTURE_CONTEXT,
			BLUR_TEXTURE_NAME,
			view_index,
			0,
			1,
			1
		)
		var depth_image := render_buffers.get_depth_layer(view_index)
		if (
			not output_image.is_valid()
			or not source_image.is_valid()
			or not blur_image.is_valid()
			or not depth_image.is_valid()
		):
			continue

		var inverse_projection := (
			scene_data.get_view_projection(view_index).inverse()
		)
		var parameter_data := _build_parameter_data(
			render_size,
			inverse_projection
		)
		_rendering_device.buffer_update(
			_parameter_buffer,
			0,
			parameter_data.size() * 4,
			parameter_data.to_byte_array()
		)

		var output_uniform := RDUniform.new()
		output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		output_uniform.binding = 0
		output_uniform.add_id(output_image)

		var source_uniform := RDUniform.new()
		source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		source_uniform.binding = 1
		source_uniform.add_id(source_image)

		var depth_uniform := RDUniform.new()
		depth_uniform.uniform_type = (
			RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		)
		depth_uniform.binding = 2
		depth_uniform.add_id(_depth_sampler)
		depth_uniform.add_id(depth_image)

		var parameter_uniform := RDUniform.new()
		parameter_uniform.uniform_type = (
			RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		)
		parameter_uniform.binding = 3
		parameter_uniform.add_id(_parameter_buffer)

		_parameter_mutex.lock()
		var wet_lens_texture_rid := _wet_lens_texture_rid
		_parameter_mutex.unlock()
		if not wet_lens_texture_rid.is_valid():
			wet_lens_texture_rid = RenderingServer.get_white_texture()
		var wet_lens_rd_texture := RenderingServer.texture_get_rd_texture(
			wet_lens_texture_rid,
			false
		)
		if not wet_lens_rd_texture.is_valid():
			continue
		var wet_lens_uniform := RDUniform.new()
		wet_lens_uniform.uniform_type = (
			RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		)
		wet_lens_uniform.binding = 4
		wet_lens_uniform.add_id(_color_sampler)
		wet_lens_uniform.add_id(wet_lens_rd_texture)

		var copy_output_uniform := RDUniform.new()
		copy_output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		copy_output_uniform.binding = 0
		copy_output_uniform.add_id(source_image)

		var copy_source_uniform := RDUniform.new()
		copy_source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		copy_source_uniform.binding = 1
		copy_source_uniform.add_id(output_image)

		var copy_uniform_set := UniformSetCacheRD.get_cache(
			_copy_shader,
			0,
			[
				copy_output_uniform,
				copy_source_uniform,
				parameter_uniform,
			]
		)
		var horizontal_output_uniform := RDUniform.new()
		horizontal_output_uniform.uniform_type = (
			RenderingDevice.UNIFORM_TYPE_IMAGE
		)
		horizontal_output_uniform.binding = 0
		horizontal_output_uniform.add_id(blur_image)

		var horizontal_source_uniform := RDUniform.new()
		horizontal_source_uniform.uniform_type = (
			RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		)
		horizontal_source_uniform.binding = 1
		horizontal_source_uniform.add_id(_color_sampler)
		horizontal_source_uniform.add_id(source_image)

		var vertical_output_uniform := RDUniform.new()
		vertical_output_uniform.uniform_type = (
			RenderingDevice.UNIFORM_TYPE_IMAGE
		)
		vertical_output_uniform.binding = 0
		vertical_output_uniform.add_id(source_image)

		var vertical_source_uniform := RDUniform.new()
		vertical_source_uniform.uniform_type = (
			RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		)
		vertical_source_uniform.binding = 1
		vertical_source_uniform.add_id(_color_sampler)
		vertical_source_uniform.add_id(blur_image)

		var horizontal_uniform_set := UniformSetCacheRD.get_cache(
			_horizontal_blur_shader,
			0,
			[
				horizontal_output_uniform,
				horizontal_source_uniform,
				parameter_uniform,
			]
		)
		var vertical_uniform_set := UniformSetCacheRD.get_cache(
			_vertical_blur_shader,
			0,
			[
				vertical_output_uniform,
				vertical_source_uniform,
				parameter_uniform,
			]
		)
		var effect_uniform_set := UniformSetCacheRD.get_cache(
			_shader,
			0,
			[
				output_uniform,
				source_uniform,
				depth_uniform,
				parameter_uniform,
				wet_lens_uniform,
			]
		)
		var compute_list := _rendering_device.compute_list_begin()
		_rendering_device.compute_list_bind_compute_pipeline(
			compute_list,
			_copy_pipeline
		)
		_rendering_device.compute_list_bind_uniform_set(
			compute_list,
			copy_uniform_set,
			0
		)
		_rendering_device.compute_list_dispatch(
			compute_list,
			group_count_x,
			group_count_y,
			1
		)
		_rendering_device.compute_list_add_barrier(compute_list)
		var pass_count := maxi(roundi(parameter_data[18]), 1)
		var underwater_blur_active := parameter_data[2] > 0.0001
		var exit_blur_active := (
			roundi(parameter_data[19]) == 2
			and parameter_data[36] < 0.9999
			and parameter_data[37] > 0.0001
		)
		if (
			(underwater_blur_active or exit_blur_active)
			and parameter_data[3] > 0.001
		):
			for _pass_index in pass_count:
				_rendering_device.compute_list_bind_compute_pipeline(
					compute_list,
					_horizontal_blur_pipeline
				)
				_rendering_device.compute_list_bind_uniform_set(
					compute_list,
					horizontal_uniform_set,
					0
				)
				_rendering_device.compute_list_dispatch(
					compute_list,
					group_count_x,
					group_count_y,
					1
				)
				_rendering_device.compute_list_add_barrier(compute_list)
				_rendering_device.compute_list_bind_compute_pipeline(
					compute_list,
					_vertical_blur_pipeline
				)
				_rendering_device.compute_list_bind_uniform_set(
					compute_list,
					vertical_uniform_set,
					0
				)
				_rendering_device.compute_list_dispatch(
					compute_list,
					group_count_x,
					group_count_y,
					1
				)
				_rendering_device.compute_list_add_barrier(compute_list)
		_rendering_device.compute_list_bind_compute_pipeline(
			compute_list,
			_pipeline
		)
		_rendering_device.compute_list_bind_uniform_set(
			compute_list,
			effect_uniform_set,
			0
		)
		_rendering_device.compute_list_dispatch(
			compute_list,
			group_count_x,
			group_count_y,
			1
		)
		_rendering_device.compute_list_end()
		rendered_any = true

	if rendered_any:
		_runtime_mutex.lock()
		_successful_render_count += 1
		_last_render_size = render_size
		_runtime_mutex.unlock()


func _build_parameter_data(
	render_size: Vector2i,
	inverse_projection: Projection
) -> PackedFloat32Array:
	var parameter_data := PackedFloat32Array()
	parameter_data.resize(PARAMETER_FLOAT_COUNT)
	_parameter_mutex.lock()
	parameter_data[0] = float(render_size.x)
	parameter_data[1] = float(render_size.y)
	parameter_data[2] = _effect_strength
	parameter_data[3] = _blur_strength
	parameter_data[4] = _underwater_tint.r
	parameter_data[5] = _underwater_tint.g
	parameter_data[6] = _underwater_tint.b
	parameter_data[7] = _underwater_tint.a
	parameter_data[8] = _fog_tint.r
	parameter_data[9] = _fog_tint.g
	parameter_data[10] = _fog_tint.b
	parameter_data[11] = _fog_tint.a
	parameter_data[12] = _tint_strength
	parameter_data[13] = _contrast
	parameter_data[14] = _fog_density
	parameter_data[15] = _fog_start_distance
	parameter_data[16] = _visibility_radius
	parameter_data[17] = _visibility_blend
	parameter_data[18] = float(_blur_passes)
	parameter_data[19] = float(_transition_mode)
	parameter_data[36] = _transition_progress
	parameter_data[37] = _transition_strength
	parameter_data[38] = _wet_lens_zoom
	parameter_data[39] = _wet_lens_warp_strength
	parameter_data[40] = _wet_lens_fall_distance
	parameter_data[41] = _wet_lens_wash_irregularity
	parameter_data[42] = _wet_lens_wash_softness
	parameter_data[43] = _wet_lens_texture_edge_feather
	_parameter_mutex.unlock()

	var write_index := 20
	for column_index in 4:
		var column: Vector4 = inverse_projection[column_index]
		parameter_data[write_index] = column.x
		parameter_data[write_index + 1] = column.y
		parameter_data[write_index + 2] = column.z
		parameter_data[write_index + 3] = column.w
		write_index += 4
	return parameter_data
