#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform writeonly image2D output_image;
layout(rgba16f, set = 0, binding = 1) uniform readonly image2D source_image;
layout(set = 0, binding = 2) uniform sampler2D depth_texture;
layout(set = 0, binding = 4) uniform sampler2D wet_lens_texture;

layout(set = 0, binding = 3, std430) readonly buffer EffectParameters {
	vec4 values[11];
} parameters;


vec4 sample_source_bilinear(vec2 uv, ivec2 size) {
	vec2 source_position = clamp(uv, vec2(0.0), vec2(1.0))
		* vec2(size) - vec2(0.5);
	ivec2 base_pixel = ivec2(floor(source_position));
	vec2 blend = fract(source_position);
	ivec2 maximum_pixel = size - ivec2(1);
	ivec2 pixel_00 = clamp(base_pixel, ivec2(0), maximum_pixel);
	ivec2 pixel_10 = clamp(
		base_pixel + ivec2(1, 0),
		ivec2(0),
		maximum_pixel
	);
	ivec2 pixel_01 = clamp(
		base_pixel + ivec2(0, 1),
		ivec2(0),
		maximum_pixel
	);
	ivec2 pixel_11 = clamp(
		base_pixel + ivec2(1, 1),
		ivec2(0),
		maximum_pixel
	);
	vec4 top = mix(
		imageLoad(source_image, pixel_00),
		imageLoad(source_image, pixel_10),
		blend.x
	);
	vec4 bottom = mix(
		imageLoad(source_image, pixel_01),
		imageLoad(source_image, pixel_11),
		blend.x
	);
	return mix(top, bottom, blend.y);
}


float random_1d(float value) {
	return fract(sin(value * 127.1) * 43758.5453);
}


float smooth_noise_1d(float value) {
	float cell = floor(value);
	float local_position = fract(value);
	float smooth_position = local_position * local_position
		* (3.0 - 2.0 * local_position);
	return mix(
		random_1d(cell),
		random_1d(cell + 1.0),
		smooth_position
	);
}


vec4 sample_crossing_transition(
	vec2 uv,
	ivec2 size,
	int transition_mode,
	float progress,
	float strength,
	float wet_lens_zoom,
	float wet_lens_warp_strength,
	float wet_lens_fall_distance,
	float wet_lens_wash_irregularity,
	float wet_lens_wash_softness,
	float wet_lens_texture_edge_feather,
	out float wet_highlight,
	out float water_wash
) {
	float aspect_ratio = float(size.x) / max(float(size.y), 1.0);
	vec2 aspect = vec2(aspect_ratio, 1.0);
	vec2 pixel_size = 1.0 / vec2(size);
	vec2 distortion = vec2(0.0);
	wet_highlight = 0.0;
	water_wash = 0.0;

	if (transition_mode == 1) {
		float envelope = (
			1.0 - smoothstep(0.45, 1.0, progress)
		) * strength;
		vec2 centered = (uv - vec2(0.5)) * aspect;
		float radial_distance = length(centered);
		float impact_wave = sin(
			radial_distance * 52.0 - progress * 42.0
		);
		vec2 radial_direction = centered / max(radial_distance, 0.001);
		radial_direction.x /= aspect_ratio;
		distortion += radial_direction * impact_wave
			* pixel_size * 7.0 * envelope;
		distortion += vec2(
			sin(uv.y * 74.0 + progress * 31.0),
			cos(uv.x * 61.0 - progress * 27.0)
		) * pixel_size * 3.5 * envelope;

		water_wash = exp(-progress * 7.0)
			* 0.42 * min(strength, 1.5);
	} else if (transition_mode == 2) {
		float exit_envelope = (
			1.0 - smoothstep(0.0, 1.0, progress)
		) * strength;
		float fade = (
			1.0 - smoothstep(0.62, 1.0, progress)
		) * strength;
		// Full-screen refraction left by the water sheet as the camera emerges.
		// It starts at maximum strength and settles continuously back to the
		// undistorted exterior image.
		vec2 exit_warp = vec2(
			sin(uv.y * 31.0 + progress * 13.0)
				+ sin(uv.y * 9.0 - progress * 7.0) * 0.55,
			cos(uv.x * 27.0 - progress * 11.0)
				+ sin((uv.x + uv.y) * 12.0 + progress * 8.0) * 0.45
		);
		distortion += exit_warp
			* pixel_size
			* 8.0
			* exit_envelope
			* wet_lens_warp_strength;
		// Use two bands of smooth noise plus a few narrow rivulets so the wet
		// edge clears at different heights instead of behaving like a flat
		// windscreen wiper.
		float broad_wipe_shape = (
			smooth_noise_1d(uv.x * 3.7 + 2.4) - 0.5
		) * 0.34;
		float detail_wipe_shape = (
			smooth_noise_1d(uv.x * 11.0 + 8.1) - 0.5
		) * 0.13;
		float rivulet_shape = pow(
			max(sin(uv.x * 39.0 + 1.7), 0.0),
			10.0
		) * 0.11;
		float wipe_height = progress
			+ (
				broad_wipe_shape
				+ detail_wipe_shape
				- rivulet_shape
			) * wet_lens_wash_irregularity;
		float safe_wash_softness = max(
			wet_lens_wash_softness,
			0.001
		);
		float draining_sheet = smoothstep(
			wipe_height - safe_wash_softness,
			wipe_height + safe_wash_softness,
			uv.y
		);
		vec2 wet_uv = (
			uv - vec2(0.5)
		) / max(wet_lens_zoom, 0.01) + vec2(0.5);
		float column_flow = sin(
			uv.x * 17.0
			+ sin(uv.x * 6.0 + progress * 4.0) * 2.2
			+ progress * 8.0
		);
		float downward_travel = progress * wet_lens_fall_distance * (
			0.82 + column_flow * 0.18
		);
		wet_uv.y -= downward_travel;
		wet_uv.x += column_flow * 0.012
			* wet_lens_warp_strength
			* (0.35 + progress * 0.65);
		wet_uv.y += sin(
			uv.x * 23.0
			+ uv.y * 7.0
			+ progress * 11.0
		) * 0.006 * wet_lens_warp_strength;
		float safe_edge_feather = max(
			wet_lens_texture_edge_feather,
			max(pixel_size.x, pixel_size.y) * 2.0
		);
		float wet_bounds = smoothstep(
			0.0,
			safe_edge_feather,
			wet_uv.x
		) * smoothstep(
			0.0,
			safe_edge_feather,
			wet_uv.y
		) * (
			1.0 - smoothstep(
				1.0 - safe_edge_feather,
				1.0,
				wet_uv.x
			)
		) * (
			1.0 - smoothstep(
				1.0 - safe_edge_feather,
				1.0,
				wet_uv.y
			)
		);
		wet_uv = clamp(wet_uv, vec2(0.0), vec2(1.0));
		float wet_height = texture(wet_lens_texture, wet_uv).r
			* wet_bounds;
		float wet_left = texture(
			wet_lens_texture,
			wet_uv - vec2(pixel_size.x * 2.0, 0.0)
		).r;
		float wet_right = texture(
			wet_lens_texture,
			wet_uv + vec2(pixel_size.x * 2.0, 0.0)
		).r;
		float wet_up = texture(
			wet_lens_texture,
			wet_uv - vec2(0.0, pixel_size.y * 2.0)
		).r;
		float wet_down = texture(
			wet_lens_texture,
			wet_uv + vec2(0.0, pixel_size.y * 2.0)
		).r;
		vec2 wet_normal = vec2(
			wet_right - wet_left,
			wet_down - wet_up
		) * wet_bounds;
		float droplet_mask = smoothstep(0.025, 0.42, wet_height)
			* draining_sheet * fade;
		distortion += wet_normal * pixel_size * 38.0
			* droplet_mask * wet_lens_warp_strength;
		distortion.y -= pixel_size.y * 12.0
			* droplet_mask
			* wet_lens_warp_strength
			* (0.35 + progress * 0.65);
		wet_highlight = smoothstep(0.30, 0.82, wet_height)
			* droplet_mask;
		water_wash = draining_sheet * 0.08 * fade;
	}

	return sample_source_bilinear(uv + distortion, size);
}


void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(parameters.values[0].xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	float effect_strength = clamp(parameters.values[0].z, 0.0, 1.0);
	int transition_mode = int(round(parameters.values[4].w));
	float transition_progress = clamp(parameters.values[9].x, 0.0, 1.0);
	float transition_strength = max(parameters.values[9].y, 0.0);
	float wet_lens_zoom = max(parameters.values[9].z, 0.01);
	float wet_lens_warp_strength = max(parameters.values[9].w, 0.0);
	float wet_lens_fall_distance = max(parameters.values[10].x, 0.0);
	float wet_lens_wash_irregularity = max(
		parameters.values[10].y,
		0.0
	);
	float wet_lens_wash_softness = max(
		parameters.values[10].z,
		0.001
	);
	float wet_lens_texture_edge_feather = max(
		parameters.values[10].w,
		0.0
	);
	bool transition_active = transition_mode != 0
		&& transition_strength > 0.0001;
	if (effect_strength <= 0.0001 && !transition_active) {
		vec4 original_color = imageLoad(source_image, pixel);
		imageStore(output_image, pixel, original_color);
		return;
	}

	vec2 screen_uv = (vec2(pixel) + vec2(0.5)) / vec2(size);
	float wet_highlight;
	float water_wash;
	vec4 original_color = transition_active
		? sample_crossing_transition(
			screen_uv,
			size,
			transition_mode,
			transition_progress,
			transition_strength,
			wet_lens_zoom,
			wet_lens_warp_strength,
			wet_lens_fall_distance,
			wet_lens_wash_irregularity,
			wet_lens_wash_softness,
			wet_lens_texture_edge_feather,
			wet_highlight,
			water_wash
		)
		: imageLoad(source_image, pixel);
	vec3 scene_color = original_color.rgb;

	vec3 underwater_tint = parameters.values[1].rgb;
	vec3 fog_tint = parameters.values[2].rgb;
	float tint_strength = clamp(parameters.values[3].x, 0.0, 1.0);
	float contrast = parameters.values[3].y;
	float fog_density = max(parameters.values[3].z, 0.0);
	float fog_start_distance = max(parameters.values[3].w, 0.0);
	float visibility_radius = max(parameters.values[4].x, 0.001);
	float visibility_blend = clamp(
		parameters.values[4].y,
		0.001,
		visibility_radius
	);

	float raw_depth = texelFetch(depth_texture, pixel, 0).r;
	float scene_distance = visibility_radius;
	if (raw_depth > 0.000001) {
		mat4 inverse_projection = mat4(
			parameters.values[5],
			parameters.values[6],
			parameters.values[7],
			parameters.values[8]
		);
		vec4 view_position = inverse_projection * vec4(
			screen_uv * 2.0 - 1.0,
			raw_depth,
			1.0
		);
		if (abs(view_position.w) > 0.000001) {
			scene_distance = length(view_position.xyz / view_position.w);
		}
	}

	scene_color = mix(
		scene_color,
		scene_color * underwater_tint,
		tint_strength * effect_strength
	);
	scene_color = (
		scene_color - vec3(0.5)
	) * mix(1.0, contrast, effect_strength) + vec3(0.5);
	scene_color = max(scene_color, vec3(0.0));

	float fog_distance = max(scene_distance - fog_start_distance, 0.0);
	float density_extinction = 1.0 - exp(-fog_density * fog_distance);
	float radius_extinction = smoothstep(
		visibility_radius - visibility_blend,
		visibility_radius,
		scene_distance
	);
	float fog_amount = max(density_extinction, radius_extinction)
		* effect_strength;
	vec3 final_color = mix(scene_color, fog_tint, fog_amount);
	vec3 composited_color = mix(
		original_color.rgb,
		final_color,
		effect_strength
	);
	if (transition_active) {
		vec3 transition_tint = mix(
			vec3(0.58, 0.84, 0.92),
			underwater_tint,
			0.42
		);
		composited_color = mix(
			composited_color,
			transition_tint,
			clamp(water_wash, 0.0, 0.65)
		);
		composited_color += vec3(0.72, 0.88, 0.92)
			* wet_highlight * 0.18;
	}

	imageStore(
		output_image,
		pixel,
		vec4(composited_color, original_color.a)
	);
}
