shader_type spatial;

render_mode cull_back;


// ============================================================
// ASPECTO DEL EDIFICIO
// ============================================================

uniform vec3 base_color : source_color = vec3(0.012, 0.015, 0.022);

uniform float roughness_value :
	hint_range(0.0, 1.0, 0.01) = 0.75;

uniform float metallic_value :
	hint_range(0.0, 1.0, 0.01) = 0.0;


// ============================================================
// VENTANAS PROCEDURALES
// ============================================================

// Número aproximado de ventanas por metro:
// X = densidad horizontal
// Y = densidad vertical
uniform vec2 windows_per_meter = vec2(1.2, 0.75);

// Tamaño de cada ventana dentro de su celda.
uniform vec2 window_fill = vec2(0.64, 0.55);

uniform float edge_softness :
	hint_range(0.0, 0.2, 0.001) = 0.015;

uniform float lit_probability :
	hint_range(0.0, 1.0, 0.01) = 0.32;

uniform vec3 window_color :
	source_color = vec3(1.0, 0.42, 0.08);

uniform float emission_strength :
	hint_range(0.0, 64.0, 0.1) = 10.0;


// ============================================================
// VARIACIÓN Y ANIMACIÓN
// ============================================================

uniform float random_seed = 0.0;

uniform bool animate_windows = true;

// Cambios por segundo.
// Mejor mantenerlo bajo para evitar efecto discoteca.
uniform float change_speed :
	hint_range(0.0, 2.0, 0.01) = 0.08;


// ============================================================
// DETECCIÓN DE PAREDES
// ============================================================

// Cuanto más bajo, más vertical debe ser la superficie.
uniform float vertical_normal_limit :
	hint_range(0.0, 1.0, 0.01) = 0.30;

uniform float vertical_fade_width :
	hint_range(0.001, 0.5, 0.001) = 0.08;


// Posición y normal locales, sin depender de UV.
varying vec3 local_position;
varying vec3 local_normal;


float hash21(vec2 p) {
	p += vec2(random_seed, random_seed * 1.371);

	return fract(
		sin(dot(p, vec2(127.1, 311.7)))
		* 43758.5453123
	);
}


float rectangle_mask(
	vec2 local_uv,
	vec2 fill_amount,
	float softness
) {
	vec2 distance_from_center = abs(local_uv - vec2(0.5));
	vec2 half_fill = fill_amount * 0.5;

	float mask_x = 1.0 - smoothstep(
		half_fill.x - softness,
		half_fill.x + softness,
		distance_from_center.x
	);

	float mask_y = 1.0 - smoothstep(
		half_fill.y - softness,
		half_fill.y + softness,
		distance_from_center.y
	);

	return mask_x * mask_y;
}


void vertex() {
	local_position = VERTEX;
	local_normal = normalize(NORMAL);
}


void fragment() {
	vec3 n = normalize(local_normal);

	// En paredes verticales abs(n.y) está cerca de 0.
	// En techo y suelo está cerca de 1.
	float vertical_mask = 1.0 - smoothstep(
		vertical_normal_limit,
		vertical_normal_limit + vertical_fade_width,
		abs(n.y)
	);

	// Elegimos automáticamente la proyección según la dirección
	// predominante de la pared.
	vec2 projected_position;

	if (abs(n.x) > abs(n.z)) {
		// Pared orientada hacia X: usamos profundidad + altura.
		projected_position = vec2(local_position.z, local_position.y);
	} else {
		// Pared orientada hacia Z: usamos anchura + altura.
		projected_position = vec2(local_position.x, local_position.y);
	}

	vec2 grid_uv = projected_position * windows_per_meter;
	vec2 cell_id = floor(grid_uv);
	vec2 cell_uv = fract(grid_uv);

	float window_shape = rectangle_mask(
		cell_uv,
		window_fill,
		edge_softness
	);

	float time_state = 0.0;

	if (animate_windows) {
		time_state = floor(TIME * change_speed);
	}

	float random_value = hash21(
		cell_id +
		vec2(
			time_state * 17.37,
			time_state * 7.91
		)
	);

	float lit_window = step(
		1.0 - lit_probability,
		random_value
	);

	float final_mask =
		window_shape *
		lit_window *
		vertical_mask;

	ALBEDO = mix(
		base_color,
		window_color * 0.12,
		final_mask
	);

	EMISSION =
		window_color *
		emission_strength *
		final_mask;

	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
}