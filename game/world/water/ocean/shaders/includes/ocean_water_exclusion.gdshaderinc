const int MAX_WATER_EXCLUSION_VOLUMES = 8;

group_uniforms WaterExclusion;
uniform int water_exclusion_volume_count : hint_range(0, 8, 1) = 0;
uniform vec4 water_exclusion_centers_radii[8];
uniform vec4 water_exclusion_inverse_rows_x[8];
uniform vec4 water_exclusion_inverse_rows_y[8];
uniform vec4 water_exclusion_inverse_rows_z[8];
group_uniforms;


bool water_position_is_excluded(vec3 world_position) {
	if (water_exclusion_volume_count <= 0) {
		return false;
	}
	for (int index = 0; index < MAX_WATER_EXCLUSION_VOLUMES; index++) {
		if (index >= water_exclusion_volume_count) {
			break;
		}
		vec4 center_radius = water_exclusion_centers_radii[index];
		vec3 center_delta = world_position - center_radius.xyz;
		if (dot(center_delta, center_delta) > center_radius.w * center_radius.w) {
			continue;
		}
		vec3 local_position = vec3(
			dot(water_exclusion_inverse_rows_x[index], vec4(world_position, 1.0)),
			dot(water_exclusion_inverse_rows_y[index], vec4(world_position, 1.0)),
			dot(water_exclusion_inverse_rows_z[index], vec4(world_position, 1.0))
		);
		if (all(lessThan(abs(local_position), vec3(0.5)))) {
			return true;
		}
	}
	return false;
}
