shader_type spatial;

render_mode skip_vertex_transform, cull_disabled;


// ============================================================
// TEXTURE
// ============================================================

uniform sampler2D tree_tex : source_color;


// ============================================================
// CUTOUT
// ============================================================

uniform float alpha_cutoff : hint_range(0.0, 1.0, 0.01) = 0.80;


// ============================================================
// VERTEX
// ============================================================

void vertex() {

	// --------------------------------------------------------
	// ORIGEN DE LA INSTANCIA
	// --------------------------------------------------------

	vec3 origin_ws = (
		MODEL_MATRIX
		* vec4(
			0.0,
			0.0,
			0.0,
			1.0
		)
	).xyz;


	// --------------------------------------------------------
	// ESCALA INDIVIDUAL DEL MULTIMESH
	// --------------------------------------------------------

	float instance_scale_x =
		length(
			MODEL_MATRIX[0].xyz
		);

	float instance_scale_y =
		length(
			MODEL_MATRIX[1].xyz
		);


	// --------------------------------------------------------
	// POSICIÓN DE LA CÁMARA DEL PASS ACTUAL
	//
	// En el shadow pass, INV_VIEW_MATRIX pertenece
	// a la cámara de la luz.
	// --------------------------------------------------------

	vec3 pass_camera_ws =
		INV_VIEW_MATRIX[3].xyz;


	// --------------------------------------------------------
	// Y BILLBOARD
	// --------------------------------------------------------

	vec3 world_up =
		vec3(
			0.0,
			1.0,
			0.0
		);


	vec3 to_camera_ws =
		pass_camera_ws
		- origin_ws;


	// Solo rotamos alrededor de Y.
	to_camera_ws.y = 0.0;


	float flat_length =
		length(
			to_camera_ws
		);


	if (flat_length < 0.0001) {

		to_camera_ws =
			vec3(
				0.0,
				0.0,
				1.0
			);

	} else {

		to_camera_ws /=
			flat_length;
	}


	vec3 right_ws =
		normalize(
			cross(
				world_up,
				to_camera_ws
			)
		);


	// --------------------------------------------------------
	// POSICIÓN FINAL DEL QUAD
	// --------------------------------------------------------

	vec3 world_vertex_position =
		origin_ws

		+ right_ws
			* VERTEX.x
			* instance_scale_x

		+ world_up
			* VERTEX.y
			* instance_scale_y;


	vec4 view_position = (
		VIEW_MATRIX

		* vec4(
			world_vertex_position,
			1.0
		)
	);


	VERTEX =
		view_position.xyz;
}


// ============================================================
// FRAGMENT
// ============================================================

void fragment() {

	vec4 tex =
		texture(
			tree_tex,
			UV
		);


	if (tex.a < alpha_cutoff) {
		discard;
	}
}