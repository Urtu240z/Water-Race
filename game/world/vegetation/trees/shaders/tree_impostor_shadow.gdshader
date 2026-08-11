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
	// INSTANCE ORIGIN IN WORLD SPACE
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
	// INSTANCE SCALE
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
	// SHADOW CAMERA DIRECTION
	//
	// INV_VIEW_MATRIX[2] is the +Z axis of the camera
	// used for the CURRENT rendering pass.
	//
	// In a directional-light shadow pass this gives us a
	// consistent direction from the scene towards the
	// light's shadow camera.
	//
	// IMPORTANT:
	// We use the orientation of the shadow camera,
	// NOT its position.
	// --------------------------------------------------------

	vec3 to_light_camera_ws =
		normalize(
			INV_VIEW_MATRIX[2].xyz
		);


	// --------------------------------------------------------
	// Y BILLBOARD
	//
	// Trees remain vertical.
	// Only rotate around world Y.
	// --------------------------------------------------------

	to_light_camera_ws.y = 0.0;


	float flat_length =
		length(
			to_light_camera_ws
		);


	if (flat_length < 0.0001) {

		to_light_camera_ws =
			vec3(
				0.0,
				0.0,
				1.0
			);

	} else {

		to_light_camera_ws /=
			flat_length;
	}


	vec3 world_up =
		vec3(
			0.0,
			1.0,
			0.0
		);


	vec3 right_ws =
		normalize(
			cross(
				world_up,
				to_light_camera_ws
			)
		);


	// --------------------------------------------------------
	// REBUILD BILLBOARD
	// --------------------------------------------------------

	vec3 world_vertex_position =

		origin_ws

		+ right_ws
			* VERTEX.x
			* instance_scale_x

		+ world_up
			* VERTEX.y
			* instance_scale_y;


	// --------------------------------------------------------
	// WORLD -> CURRENT PASS VIEW SPACE
	// --------------------------------------------------------

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