shader_type spatial;

/*
	Practical Real-Time Hex-Tiling for Godot 4.
	Based on Morten S. Mikkelsen, "Practical Real-Time Hex-Tiling" (2022).

	MIT License

	Copyright (c) 2022 Morten S. Mikkelsen

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
*/

const float PI_F = 3.14159265358979323846;

uniform bool use_baked_tree_shadows = false;
uniform sampler2D tree_shadow_map : repeat_disable, filter_linear_mipmap;
uniform vec2 tree_shadow_world_min = vec2(0.0, 0.0);
uniform vec2 tree_shadow_world_size = vec2(1.0, 1.0);
uniform float tree_shadow_strength : hint_range(0.0, 20.0, 0.01) = 1.0;


// ============================================================
// ARENA SECA
// ============================================================

group_uniforms DrySand;

uniform sampler2D dry_sand_albedo
	: source_color, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D dry_sand_orm
	: hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D dry_sand_normal
	: hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec4 dry_sand_tint
	: source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float dry_sand_brightness
	: hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float dry_sand_contrast
	: hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float dry_sand_saturation
	: hint_range(0.0, 2.0, 0.01) = 1.0;


// ============================================================
// ARENA HUMEDA
// ============================================================

group_uniforms WetSand;

uniform sampler2D wet_sand_albedo
	: source_color, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D wet_sand_orm
	: hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D wet_sand_normal
	: hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec4 wet_sand_tint
	: source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float wet_sand_brightness
	: hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float wet_sand_contrast
	: hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float wet_sand_saturation
	: hint_range(0.0, 2.0, 0.01) = 1.0;


// ============================================================
// CESPED
// ============================================================

group_uniforms Grass;

uniform sampler2D grass_albedo
	: source_color, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D grass_orm
	: hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D grass_normal
	: hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec4 grass_tint
	: source_color = vec4(0.75, 1.0, 0.65, 1.0);

uniform float grass_brightness
	: hint_range(0.0, 2.0, 0.01) = 1.25;

uniform float grass_contrast
	: hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float grass_saturation
	: hint_range(0.0, 2.0, 0.01) = 1.0;


// ============================================================
// ROCA
// ============================================================

group_uniforms Rock;

uniform sampler2D rock_albedo
	: source_color, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D rock_orm
	: hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D rock_normal
	: hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec4 rock_tint
	: source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float rock_brightness
	: hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float rock_contrast
	: hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float rock_saturation
	: hint_range(0.0, 2.0, 0.01) = 1.0;


// ============================================================
// MUSGO
// ============================================================

group_uniforms Moss;

uniform sampler2D moss_albedo
	: source_color, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D moss_orm
	: hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

uniform sampler2D moss_normal
	: hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;

uniform vec4 moss_tint
	: source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float moss_brightness
	: hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float moss_contrast
	: hint_range(0.0, 2.0, 0.01) = 1.0;

uniform float moss_saturation
	: hint_range(0.0, 2.0, 0.01) = 1.0;


// ============================================================
// ESCALA Y TRIPLANAR
// ============================================================

group_uniforms Projection;

uniform float sand_tile_size
	: hint_range(0.25, 20.0, 0.05) = 3.0;

uniform float grass_tile_size
	: hint_range(0.25, 20.0, 0.05) = 3.0;

uniform float rock_tile_size
	: hint_range(0.25, 100.0, 0.05) = 4.0;

uniform float moss_tile_size
	: hint_range(0.25, 20.0, 0.05) = 3.0;

uniform float triplanar_sharpness
	: hint_range(1.0, 16.0, 0.25) = 4.0;


// ============================================================
// INTENSIDAD DE NORMALES
// ============================================================

group_uniforms NormalStrength;

uniform float dry_sand_normal_strength
	: hint_range(0.0, 2.0, 0.05) = 1.0;

uniform float wet_sand_normal_strength
	: hint_range(0.0, 2.0, 0.05) = 1.0;

uniform float grass_normal_strength
	: hint_range(0.0, 2.0, 0.05) = 1.0;

uniform float rock_normal_strength
	: hint_range(0.0, 2.0, 0.05) = 1.0;

uniform float moss_normal_strength
	: hint_range(0.0, 2.0, 0.05) = 1.0;


// ============================================================
// HEX-TILING ESTOCASTICO
//
// Off:             triplanar normal.
// Albedo:          rompe solo el color.
// Albedo + Normal: recomendado.
// Full PBR:        rompe tambien el ORM; mas caro.
// ============================================================

group_uniforms HexTiling;

uniform int hex_tiling_mode
	: hint_enum("Off", "Albedo", "Albedo + Normal", "Full PBR") = 2;

uniform float hex_rotation_strength
	: hint_range(0.0, 1.0, 0.01) = 1.0;

uniform float hex_weight_contrast
	: hint_range(0.01, 0.99, 0.01) = 0.75;

uniform float hex_luminance_influence
	: hint_range(0.0, 1.0, 0.01) = 0.60;

uniform float hex_blend_exponent
	: hint_range(1.0, 16.0, 0.25) = 7.0;

uniform float material_sample_threshold
	: hint_range(0.0, 0.05, 0.001) = 0.002;


// ============================================================
// ARENA HUMEDA
// ============================================================

group_uniforms WetSandTransition;

uniform float water_level = -1.02;

uniform float wet_sand_height
	: hint_range(0.1, 5.0, 0.05) = 1.5;


// ============================================================
// DIAGNOSTICO
// ============================================================

group_uniforms Debug;

uniform int debug_view
	: hint_enum(
		"Final",
		"Mascara RGB",
		"Peso cesped",
		"Textura cesped"
	) = 0;

group_uniforms;


// ============================================================
// DATOS EN ESPACIO GLOBAL
// ============================================================

varying vec3 world_position;
varying vec3 world_normal;


void vertex() {
	world_position = (
		MODEL_MATRIX * vec4(VERTEX, 1.0)
	).xyz;

	world_normal = normalize(
		MODEL_NORMAL_MATRIX * NORMAL
	);
}


// ============================================================
// AJUSTES DEL ALBEDO
// ============================================================

vec3 adjust_albedo(
	vec3 color,
	vec4 tint,
	float brightness,
	float contrast,
	float saturation
) {
	color *= tint.rgb;

	float luminance = dot(
		color,
		vec3(0.2126, 0.7152, 0.0722)
	);

	color = mix(
		vec3(luminance),
		color,
		saturation
	);

	color = (
		color - vec3(0.18)
	) * contrast + vec3(0.18);

	color *= brightness;

	return clamp(
		color,
		vec3(0.0),
		vec3(1.0)
	);
}


// ============================================================
// DECODIFICACION DEL NORMAL MAP
// ============================================================

vec3 unpack_normal_map(
	vec3 packed_normal,
	float strength
) {
	vec2 normal_xy = (
		packed_normal.rg * 2.0 - 1.0
	) * strength;

	float normal_z = sqrt(
		max(
			1.0 - dot(normal_xy, normal_xy),
			0.0001
		)
	);

	return normalize(
		vec3(normal_xy, normal_z)
	);
}


// ============================================================
// HEX-TILING: CUADRICULA TRIANGULAR
// ============================================================

void triangle_grid(
	out float weight_1,
	out float weight_2,
	out float weight_3,
	out ivec2 vertex_1,
	out ivec2 vertex_2,
	out ivec2 vertex_3,
	vec2 coordinates
) {
	coordinates *= 2.0 * sqrt(3.0);

	mat2 grid_to_skewed = mat2(
		vec2(1.0, 0.0),
		vec2(-0.57735027, 1.15470054)
	);

	vec2 skewed = grid_to_skewed * coordinates;
	ivec2 base_id = ivec2(floor(skewed));

	vec3 temporary = vec3(
		fract(skewed),
		0.0
	);

	temporary.z = (
		1.0 -
		temporary.x -
		temporary.y
	);

	float selector = step(
		0.0,
		-temporary.z
	);

	float selector_sign = (
		2.0 * selector - 1.0
	);

	weight_1 = -temporary.z * selector_sign;
	weight_2 = selector - temporary.y * selector_sign;
	weight_3 = selector - temporary.x * selector_sign;

	vertex_1 = base_id + ivec2(
		int(selector),
		int(selector)
	);

	vertex_2 = base_id + ivec2(
		int(selector),
		int(1.0 - selector)
	);

	vertex_3 = base_id + ivec2(
		int(1.0 - selector),
		int(selector)
	);
}


vec2 hash_22(
	vec2 value,
	float seed
) {
	vec2 seeded_value = value + vec2(
		seed * 13.37,
		seed * 7.91
	);

	mat2 hash_matrix = mat2(
		vec2(127.1, 269.5),
		vec2(311.7, 183.3)
	);

	vec2 result = hash_matrix * seeded_value;

	return fract(
		sin(result) * 43758.5453
	);
}


vec2 make_center_st(
	ivec2 vertex
) {
	mat2 inverse_skew = mat2(
		vec2(1.0, 0.0),
		vec2(0.5, 1.0 / 1.15470054)
	);

	return (
		inverse_skew * vec2(vertex)
	) / (
		2.0 * sqrt(3.0)
	);
}


mat2 load_rotation_2x2(
	ivec2 index,
	float rotation_strength,
	float seed
) {
	float angle = (
		abs(float(index.x * index.y)) +
		abs(float(index.x + index.y)) +
		PI_F +
		seed * 1.61803398875
	);

	angle = mod(
		angle,
		2.0 * PI_F
	);

	if (angle < 0.0) {
		angle += 2.0 * PI_F;
	}

	if (angle > PI_F) {
		angle -= 2.0 * PI_F;
	}

	angle *= rotation_strength;

	float cosine_value = cos(angle);
	float sine_value = sin(angle);

	return mat2(
		vec2(cosine_value, sine_value),
		vec2(-sine_value, cosine_value)
	);
}


vec3 gain_weights(
	vec3 weights,
	float contrast_value
) {
	float exponent_value = (
		log(1.0 - contrast_value) /
		log(0.5)
	);

	vec3 side = 2.0 * step(
		vec3(0.5),
		weights
	);

	vec3 multiplier = 2.0 * (
		1.0 - side
	);

	vec3 result = (
		0.5 * side +
		0.25 * multiplier *
		pow(
			max(
				vec3(0.0),
				side + weights * multiplier
			),
			vec3(exponent_value)
		)
	);

	return result / max(
		result.x + result.y + result.z,
		0.0001
	);
}


// ============================================================
// HEX-TILING: MUESTREO PBR 2D COHERENTE
// ============================================================

void sample_hex_pbr_2d(
	sampler2D albedo_sampler,
	sampler2D orm_sampler,
	sampler2D normal_sampler,
	vec2 coordinates,
	vec2 coordinates_dx,
	vec2 coordinates_dy,
	float normal_strength,
	float seed,
	out vec3 sampled_albedo,
	out vec3 sampled_orm,
	out vec3 sampled_normal_ts
) {
	if (hex_tiling_mode == 0) {
		sampled_albedo = textureGrad(
			albedo_sampler,
			coordinates,
			coordinates_dx,
			coordinates_dy
		).rgb;

		sampled_orm = textureGrad(
			orm_sampler,
			coordinates,
			coordinates_dx,
			coordinates_dy
		).rgb;

		sampled_normal_ts = unpack_normal_map(
			textureGrad(
				normal_sampler,
				coordinates,
				coordinates_dx,
				coordinates_dy
			).rgb,
			normal_strength
		);

		return;
	}

	float barycentric_1 = 0.0;
	float barycentric_2 = 0.0;
	float barycentric_3 = 0.0;

	ivec2 vertex_1 = ivec2(0);
	ivec2 vertex_2 = ivec2(0);
	ivec2 vertex_3 = ivec2(0);

	triangle_grid(
		barycentric_1,
		barycentric_2,
		barycentric_3,
		vertex_1,
		vertex_2,
		vertex_3,
		coordinates
	);

	mat2 rotation_1 = load_rotation_2x2(
		vertex_1,
		hex_rotation_strength,
		seed
	);

	mat2 rotation_2 = load_rotation_2x2(
		vertex_2,
		hex_rotation_strength,
		seed
	);

	mat2 rotation_3 = load_rotation_2x2(
		vertex_3,
		hex_rotation_strength,
		seed
	);

	vec2 center_1 = make_center_st(vertex_1);
	vec2 center_2 = make_center_st(vertex_2);
	vec2 center_3 = make_center_st(vertex_3);

	vec2 coordinates_1 = (
		rotation_1 * (coordinates - center_1) +
		center_1 +
		hash_22(vec2(vertex_1), seed)
	);

	vec2 coordinates_2 = (
		rotation_2 * (coordinates - center_2) +
		center_2 +
		hash_22(vec2(vertex_2), seed)
	);

	vec2 coordinates_3 = (
		rotation_3 * (coordinates - center_3) +
		center_3 +
		hash_22(vec2(vertex_3), seed)
	);

	vec2 dx_1 = rotation_1 * coordinates_dx;
	vec2 dy_1 = rotation_1 * coordinates_dy;
	vec2 dx_2 = rotation_2 * coordinates_dx;
	vec2 dy_2 = rotation_2 * coordinates_dy;
	vec2 dx_3 = rotation_3 * coordinates_dx;
	vec2 dy_3 = rotation_3 * coordinates_dy;

	vec3 albedo_1 = textureGrad(
		albedo_sampler,
		coordinates_1,
		dx_1,
		dy_1
	).rgb;

	vec3 albedo_2 = textureGrad(
		albedo_sampler,
		coordinates_2,
		dx_2,
		dy_2
	).rgb;

	vec3 albedo_3 = textureGrad(
		albedo_sampler,
		coordinates_3,
		dx_3,
		dy_3
	).rgb;

	vec3 luminance_weights = vec3(
		dot(albedo_1, vec3(0.299, 0.587, 0.114)),
		dot(albedo_2, vec3(0.299, 0.587, 0.114)),
		dot(albedo_3, vec3(0.299, 0.587, 0.114))
	);

	luminance_weights = mix(
		vec3(1.0),
		luminance_weights,
		hex_luminance_influence
	);

	vec3 blend_weights = (
		luminance_weights *
		pow(
			max(
				vec3(
					barycentric_1,
					barycentric_2,
					barycentric_3
				),
				vec3(0.0001)
			),
			vec3(hex_blend_exponent)
		)
	);

	blend_weights /= max(
		blend_weights.x +
		blend_weights.y +
		blend_weights.z,
		0.0001
	);

	if (
		abs(hex_weight_contrast - 0.5) > 0.0001
	) {
		blend_weights = gain_weights(
			blend_weights,
			hex_weight_contrast
		);
	}

	sampled_albedo = (
		albedo_1 * blend_weights.x +
		albedo_2 * blend_weights.y +
		albedo_3 * blend_weights.z
	);

	if (hex_tiling_mode >= 3) {
		vec3 orm_1 = textureGrad(
			orm_sampler,
			coordinates_1,
			dx_1,
			dy_1
		).rgb;

		vec3 orm_2 = textureGrad(
			orm_sampler,
			coordinates_2,
			dx_2,
			dy_2
		).rgb;

		vec3 orm_3 = textureGrad(
			orm_sampler,
			coordinates_3,
			dx_3,
			dy_3
		).rgb;

		sampled_orm = (
			orm_1 * blend_weights.x +
			orm_2 * blend_weights.y +
			orm_3 * blend_weights.z
		);
	} else {
		sampled_orm = textureGrad(
			orm_sampler,
			coordinates,
			coordinates_dx,
			coordinates_dy
		).rgb;
	}

	if (hex_tiling_mode >= 2) {
		vec3 normal_1 = unpack_normal_map(
			textureGrad(
				normal_sampler,
				coordinates_1,
				dx_1,
				dy_1
			).rgb,
			normal_strength
		);

		vec3 normal_2 = unpack_normal_map(
			textureGrad(
				normal_sampler,
				coordinates_2,
				dx_2,
				dy_2
			).rgb,
			normal_strength
		);

		vec3 normal_3 = unpack_normal_map(
			textureGrad(
				normal_sampler,
				coordinates_3,
				dx_3,
				dy_3
			).rgb,
			normal_strength
		);

		normal_1 = normalize(
			vec3(
				transpose(rotation_1) * normal_1.xy,
				normal_1.z
			)
		);

		normal_2 = normalize(
			vec3(
				transpose(rotation_2) * normal_2.xy,
				normal_2.z
			)
		);

		normal_3 = normalize(
			vec3(
				transpose(rotation_3) * normal_3.xy,
				normal_3.z
			)
		);

		sampled_normal_ts = normalize(
			normal_1 * blend_weights.x +
			normal_2 * blend_weights.y +
			normal_3 * blend_weights.z
		);
	} else {
		sampled_normal_ts = unpack_normal_map(
			textureGrad(
				normal_sampler,
				coordinates,
				coordinates_dx,
				coordinates_dy
			).rgb,
			normal_strength
		);
	}
}


// ============================================================
// MUESTREO TRIPLANAR DE UN MATERIAL COMPLETO
// ============================================================

vec3 get_triplanar_weights(
	vec3 normal_ws
) {
	vec3 weights = pow(
		abs(normal_ws),
		vec3(triplanar_sharpness)
	);

	return weights / max(
		weights.x + weights.y + weights.z,
		0.0001
	);
}


void sample_material_triplanar(
	sampler2D albedo_sampler,
	sampler2D orm_sampler,
	sampler2D normal_sampler,
	vec3 position_ws,
	vec3 position_dx,
	vec3 position_dy,
	vec3 geometric_normal_ws,
	float tile_size,
	float normal_strength,
	float material_seed,
	out vec3 sampled_albedo,
	out vec3 sampled_orm,
	out vec3 sampled_normal_ws
) {
	vec3 projection_weights = get_triplanar_weights(
		geometric_normal_ws
	);

	float safe_tile_size = max(
		tile_size,
		0.001
	);

	vec3 coordinates = position_ws / safe_tile_size;
	vec3 coordinates_dx = position_dx / safe_tile_size;
	vec3 coordinates_dy = position_dy / safe_tile_size;

	vec3 albedo_x = vec3(0.0);
	vec3 albedo_y = vec3(0.0);
	vec3 albedo_z = vec3(0.0);

	vec3 orm_x = vec3(1.0);
	vec3 orm_y = vec3(1.0);
	vec3 orm_z = vec3(1.0);

	vec3 normal_x = vec3(0.0, 0.0, 1.0);
	vec3 normal_y = vec3(0.0, 0.0, 1.0);
	vec3 normal_z = vec3(0.0, 0.0, 1.0);

	sample_hex_pbr_2d(
		albedo_sampler,
		orm_sampler,
		normal_sampler,
		coordinates.zy,
		coordinates_dx.zy,
		coordinates_dy.zy,
		normal_strength,
		material_seed + 11.0,
		albedo_x,
		orm_x,
		normal_x
	);

	sample_hex_pbr_2d(
		albedo_sampler,
		orm_sampler,
		normal_sampler,
		coordinates.xz,
		coordinates_dx.xz,
		coordinates_dy.xz,
		normal_strength,
		material_seed + 23.0,
		albedo_y,
		orm_y,
		normal_y
	);

	sample_hex_pbr_2d(
		albedo_sampler,
		orm_sampler,
		normal_sampler,
		coordinates.xy,
		coordinates_dx.xy,
		coordinates_dy.xy,
		normal_strength,
		material_seed + 37.0,
		albedo_z,
		orm_z,
		normal_z
	);

	sampled_albedo = (
		albedo_x * projection_weights.x +
		albedo_y * projection_weights.y +
		albedo_z * projection_weights.z
	);

	sampled_orm = (
		orm_x * projection_weights.x +
		orm_y * projection_weights.y +
		orm_z * projection_weights.z
	);

	float sign_x = (
		geometric_normal_ws.x < 0.0
		? -1.0
		: 1.0
	);

	float sign_y = (
		geometric_normal_ws.y < 0.0
		? -1.0
		: 1.0
	);

	float sign_z = (
		geometric_normal_ws.z < 0.0
		? -1.0
		: 1.0
	);

	vec3 world_normal_x = vec3(
		sign_x * normal_x.z,
		normal_x.y,
		-sign_x * normal_x.x
	);

	vec3 world_normal_y = vec3(
		-sign_y * normal_y.x,
		sign_y * normal_y.z,
		normal_y.y
	);

	vec3 world_normal_z = vec3(
		sign_z * normal_z.x,
		normal_z.y,
		sign_z * normal_z.z
	);

	sampled_normal_ws = normalize(
		world_normal_x * projection_weights.x +
		world_normal_y * projection_weights.y +
		world_normal_z * projection_weights.z
	);
}


// ============================================================
// FRAGMENT
// ============================================================

void fragment() {
	vec3 normal_ws = normalize(
		world_normal
	);

	// Las derivadas se calculan fuera de ramas variables.
	vec3 world_position_dx = dFdx(
		world_position
	);

	vec3 world_position_dy = dFdy(
		world_position
	);

	float sand_mask = clamp(
		1.0 - COLOR.r - COLOR.g - COLOR.b,
		0.0,
		1.0
	);

	vec4 material_weights = vec4(
		sand_mask,
		COLOR.g,
		COLOR.r,
		COLOR.b
	);

	float weight_total = (
		material_weights.x +
		material_weights.y +
		material_weights.z +
		material_weights.w
	);

	material_weights /= max(
		weight_total,
		0.0001
	);

	float wetness = 1.0 - smoothstep(
		water_level + 0.10,
		water_level + wet_sand_height,
		world_position.y
	);

	vec3 final_sand_albedo = vec3(0.0);
	vec3 final_sand_orm = vec3(1.0);
	vec3 final_sand_normal = normal_ws;

	vec3 grass_albedo_sample = vec3(0.0);
	vec3 grass_orm_sample = vec3(1.0);
	vec3 grass_normal_sample = normal_ws;

	vec3 rock_albedo_sample = vec3(0.0);
	vec3 rock_orm_sample = vec3(1.0);
	vec3 rock_normal_sample = normal_ws;

	vec3 moss_albedo_sample = vec3(0.0);
	vec3 moss_orm_sample = vec3(1.0);
	vec3 moss_normal_sample = normal_ws;


	// --------------------------------------------------------
	// ARENA
	// --------------------------------------------------------

	if (
		material_weights.x >
		material_sample_threshold
	) {
		vec3 dry_albedo = vec3(0.0);
		vec3 dry_orm = vec3(1.0);
		vec3 dry_normal = normal_ws;

		vec3 wet_albedo = vec3(0.0);
		vec3 wet_orm = vec3(1.0);
		vec3 wet_normal = normal_ws;

		if (wetness < 0.999) {
			sample_material_triplanar(
				dry_sand_albedo,
				dry_sand_orm,
				dry_sand_normal,
				world_position,
				world_position_dx,
				world_position_dy,
				normal_ws,
				sand_tile_size,
				dry_sand_normal_strength,
				10.0,
				dry_albedo,
				dry_orm,
				dry_normal
			);

			dry_albedo = adjust_albedo(
				dry_albedo,
				dry_sand_tint,
				dry_sand_brightness,
				dry_sand_contrast,
				dry_sand_saturation
			);
		}

		if (wetness > 0.001) {
			sample_material_triplanar(
				wet_sand_albedo,
				wet_sand_orm,
				wet_sand_normal,
				world_position,
				world_position_dx,
				world_position_dy,
				normal_ws,
				sand_tile_size,
				wet_sand_normal_strength,
				20.0,
				wet_albedo,
				wet_orm,
				wet_normal
			);

			wet_albedo = adjust_albedo(
				wet_albedo,
				wet_sand_tint,
				wet_sand_brightness,
				wet_sand_contrast,
				wet_sand_saturation
			);
		}

		if (wetness <= 0.001) {
			final_sand_albedo = dry_albedo;
			final_sand_orm = dry_orm;
			final_sand_normal = dry_normal;
		} else if (wetness >= 0.999) {
			final_sand_albedo = wet_albedo;
			final_sand_orm = wet_orm;
			final_sand_normal = wet_normal;
		} else {
			final_sand_albedo = mix(
				dry_albedo,
				wet_albedo,
				wetness
			);

			final_sand_orm = mix(
				dry_orm,
				wet_orm,
				wetness
			);

			final_sand_normal = normalize(
				mix(
					dry_normal,
					wet_normal,
					wetness
				)
			);
		}
	}


	// --------------------------------------------------------
	// CESPED
	// --------------------------------------------------------

	if (
		material_weights.y >
		material_sample_threshold ||
		debug_view == 3
	) {
		sample_material_triplanar(
			grass_albedo,
			grass_orm,
			grass_normal,
			world_position,
			world_position_dx,
			world_position_dy,
			normal_ws,
			grass_tile_size,
			grass_normal_strength,
			30.0,
			grass_albedo_sample,
			grass_orm_sample,
			grass_normal_sample
		);

		grass_albedo_sample = adjust_albedo(
			grass_albedo_sample,
			grass_tint,
			grass_brightness,
			grass_contrast,
			grass_saturation
		);
	}


	// --------------------------------------------------------
	// ROCA
	// --------------------------------------------------------

	if (
		material_weights.z >
		material_sample_threshold
	) {
		sample_material_triplanar(
			rock_albedo,
			rock_orm,
			rock_normal,
			world_position,
			world_position_dx,
			world_position_dy,
			normal_ws,
			rock_tile_size,
			rock_normal_strength,
			40.0,
			rock_albedo_sample,
			rock_orm_sample,
			rock_normal_sample
		);

		rock_albedo_sample = adjust_albedo(
			rock_albedo_sample,
			rock_tint,
			rock_brightness,
			rock_contrast,
			rock_saturation
		);
	}


	// --------------------------------------------------------
	// MUSGO
	// --------------------------------------------------------

	if (
		material_weights.w >
		material_sample_threshold
	) {
		sample_material_triplanar(
			moss_albedo,
			moss_orm,
			moss_normal,
			world_position,
			world_position_dx,
			world_position_dy,
			normal_ws,
			moss_tile_size,
			moss_normal_strength,
			50.0,
			moss_albedo_sample,
			moss_orm_sample,
			moss_normal_sample
		);

		moss_albedo_sample = adjust_albedo(
			moss_albedo_sample,
			moss_tint,
			moss_brightness,
			moss_contrast,
			moss_saturation
		);
	}


	// --------------------------------------------------------
	// MEZCLA FINAL
	// --------------------------------------------------------

	vec3 final_albedo = (
		final_sand_albedo * material_weights.x +
		grass_albedo_sample * material_weights.y +
		rock_albedo_sample * material_weights.z +
		moss_albedo_sample * material_weights.w
	);

	vec3 final_orm = (
		final_sand_orm * material_weights.x +
		grass_orm_sample * material_weights.y +
		rock_orm_sample * material_weights.z +
		moss_orm_sample * material_weights.w
	);

	vec3 final_normal_ws = normalize(
		final_sand_normal * material_weights.x +
		grass_normal_sample * material_weights.y +
		rock_normal_sample * material_weights.z +
		moss_normal_sample * material_weights.w
	);


float baked_tree_shadow = 0.0;

if (use_baked_tree_shadows) {
	vec2 shadow_uv =
		(world_position.xz - tree_shadow_world_min)
		/ max(tree_shadow_world_size, vec2(0.001));

	shadow_uv.y = 1.0 - shadow_uv.y;

	if (
		shadow_uv.x >= 0.0 && shadow_uv.x <= 1.0 &&
		shadow_uv.y >= 0.0 && shadow_uv.y <= 1.0
	) {
		baked_tree_shadow = texture(
			tree_shadow_map,
			shadow_uv
		).r;
	}
}

final_albedo *= (
	1.0 - baked_tree_shadow * tree_shadow_strength
);

	// --------------------------------------------------------
	// SALIDA / DEBUG
	// --------------------------------------------------------

	if (debug_view == 0) {
		ALBEDO = final_albedo;

		AO = final_orm.r;
		ROUGHNESS = final_orm.g;
		METALLIC = final_orm.b;

		NORMAL = normalize(
			mat3(VIEW_MATRIX) *
			final_normal_ws
		);
	} else {
		vec3 debug_color = vec3(0.0);

		if (debug_view == 1) {
			debug_color = COLOR.rgb;
		} else if (debug_view == 2) {
			debug_color = vec3(
				material_weights.y
			);
		} else if (debug_view == 3) {
			debug_color = grass_albedo_sample;
		}

		ALBEDO = vec3(0.0);
		EMISSION = debug_color;

		AO = 1.0;
		ROUGHNESS = 1.0;
		METALLIC = 0.0;

		NORMAL = normalize(
			mat3(VIEW_MATRIX) *
			normal_ws
		);
	}
}
