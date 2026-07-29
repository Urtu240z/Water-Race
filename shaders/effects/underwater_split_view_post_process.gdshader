shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

const int MAX_RIPPLES = 12;
const int MAX_WATERLINE_ITERATIONS = 2;
const float TAU_VALUE = 6.28318530718;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

// Ocean3D supplies the same texture-driven surface state used by gameplay.
uniform bool ocean_enabled = true;
uniform float water_level = 0.0;
uniform float simulation_time = 0.0;
uniform sampler2D wave_height_texture_a : repeat_enable, filter_linear;
uniform sampler2D wave_height_texture_b : repeat_enable, filter_linear;
uniform float wave_world_size_a = 180.0;
uniform float wave_world_size_b = 72.0;
uniform float wave_amplitude_a = 1.35;
uniform float wave_amplitude_b = 0.42;
uniform vec2 wave_direction_a = vec2(0.86, 0.51);
uniform vec2 wave_direction_b = vec2(-0.38, 0.92);
uniform float wave_travel_speed_a = 4.6;
uniform float wave_travel_speed_b = 2.3;
uniform float wave_mean_a = 0.50;
uniform float wave_mean_b = 0.47;
uniform vec2 ocean_logical_origin_offset_xz = vec2(0.0);
uniform int ripple_active[12];
uniform vec2 ripple_positions[12];
uniform float ripple_start_times[12];
uniform float ripple_amplitudes[12];
uniform float ripple_speeds[12];
uniform float ripple_wavelengths[12];
uniform float ripple_decays[12];
uniform float ripple_lifetimes[12];

uniform float camera_submersion : hint_range(0.0, 1.0) = 0.0;
uniform float camera_depth = -1.0;
uniform vec4 underwater_tint : source_color = vec4(0.10, 0.40, 0.50, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.16;
uniform float contrast : hint_range(0.25, 1.5) = 0.94;
uniform vec4 fog_color : source_color = vec4(0.015, 0.095, 0.13, 1.0);
uniform float fog_density : hint_range(0.0, 0.1, 0.001) = 0.009;
uniform float sky_fog_density : hint_range(0.0, 0.1, 0.001) = 0.007;
uniform float sky_maximum_fog : hint_range(0.0, 1.0, 0.01) = 0.72;
uniform float geometry_maximum_fog : hint_range(0.0, 1.0, 0.01) = 0.88;
uniform vec3 absorption_coefficients = vec3(0.022, 0.010, 0.005);
uniform float minimum_scene_visibility : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float near_clarity_distance : hint_range(0.0, 30.0, 0.5) = 7.0;
uniform float fog_start_distance : hint_range(0.0, 50.0, 0.5) = 5.0;
uniform float blur_start_distance : hint_range(0.0, 50.0, 0.5) = 8.0;
uniform float distortion_strength : hint_range(0.0, 0.01) = 0.0008;
uniform float distortion_speed : hint_range(0.0, 5.0) = 0.7;
uniform float waterline_blend_width : hint_range(0.01, 1.0) = 0.28;
uniform float waterline_distortion_strength : hint_range(0.0, 0.1, 0.001) = 0.012;
uniform float waterline_distortion_scale : hint_range(1.0, 100.0, 1.0) = 28.0;
uniform float waterline_band_strength : hint_range(0.0, 0.5, 0.01) = 0.08;
uniform float waterline_band_width : hint_range(0.001, 0.5, 0.001) = 0.06;
uniform float maximum_effect_strength : hint_range(0.0, 1.0) = 1.0;
uniform int waterline_iterations : hint_range(1, 2, 1) = 1;
uniform bool waterline_include_ripples = false;
uniform float underwater_sky_distance : hint_range(10.0, 200.0, 1.0) = 45.0;
uniform float blur_density : hint_range(0.0, 0.25, 0.001) = 0.010;
uniform float blur_near_lod : hint_range(0.0, 4.0, 0.05) = 0.0;
uniform float blur_far_lod : hint_range(0.0, 1.2, 0.05) = 0.85;
uniform int debug_mode : hint_range(0, 7, 1) = 0;


vec2 safe_direction(vec2 direction, vec2 fallback) {
    float magnitude = length(direction);
    return magnitude > 0.00001 ? direction / magnitude : fallback;
}


float sample_macro_height(vec2 logical_xz) {
    float safe_size_a = max(wave_world_size_a, 0.001);
    float safe_size_b = max(wave_world_size_b, 0.001);
    vec2 uv_a = logical_xz / safe_size_a
        + safe_direction(wave_direction_a, vec2(1.0, 0.0))
            * simulation_time * wave_travel_speed_a / safe_size_a;
    vec2 uv_b = logical_xz / safe_size_b
        + safe_direction(wave_direction_b, vec2(0.0, -1.0))
            * simulation_time * wave_travel_speed_b / safe_size_b
        + vec2(0.307, 0.476);
    float height = (
        texture(wave_height_texture_a, uv_a).r - wave_mean_a
    ) * wave_amplitude_a;
    height += (
        texture(wave_height_texture_b, uv_b).r - wave_mean_b
    ) * wave_amplitude_b;
    return height;
}


float sample_ripple_height(vec2 logical_xz) {
    float height = 0.0;
    for (int index = 0; index < MAX_RIPPLES; index++) {
        if (ripple_active[index] == 0) {
            continue;
        }
        float age = simulation_time - ripple_start_times[index];
        if (age < 0.0 || age > ripple_lifetimes[index]) {
            continue;
        }
        float radius = age * ripple_speeds[index];
        float distance_to_center = length(logical_xz - ripple_positions[index]);
        float wavelength = max(ripple_wavelengths[index], 0.05);
        float shell_width = max(wavelength * 1.35, 0.1);
        float shell_offset = distance_to_center - radius;
        float normalized_shell = shell_offset / shell_width;
        float envelope = exp(-normalized_shell * normalized_shell)
            * exp(-age * ripple_decays[index])
            * smoothstep(0.0, 0.18, age);
        height += sin(shell_offset * TAU_VALUE / wavelength)
            * ripple_amplitudes[index] * envelope;
    }
    return height;
}


float sample_waterline_height(vec2 world_xz) {
    if (!ocean_enabled) {
        return water_level;
    }
    vec2 logical_xz = world_xz + ocean_logical_origin_offset_xz;
    float height = water_level + sample_macro_height(logical_xz);
    if (waterline_include_ripples) {
        height += sample_ripple_height(logical_xz);
    }
    return height;
}


vec3 reconstruct_view_position(
    vec2 screen_uv,
    float raw_depth,
    mat4 inverse_projection
) {
    if (raw_depth <= 0.000001) {
        return vec3(0.0);
    }
    vec4 view_position = inverse_projection * vec4(
        screen_uv * 2.0 - 1.0,
        raw_depth,
        1.0
    );
    if (abs(view_position.w) <= 0.000001) {
        return vec3(0.0);
    }
    return view_position.xyz / view_position.w;
}


vec3 view_to_world_position(
    vec3 view_position,
    mat4 inverse_view
) {
    return (inverse_view * vec4(view_position, 1.0)).xyz;
}


vec3 reconstruct_world_ray(
    vec2 screen_uv,
    mat4 inverse_projection,
    mat4 inverse_view
) {
    vec4 view_near = inverse_projection * vec4(
        screen_uv * 2.0 - 1.0,
        1.0,
        1.0
    );
    if (abs(view_near.w) <= 0.000001) {
        return vec3(0.0);
    }
    vec3 view_direction = normalize(view_near.xyz / view_near.w);
    return normalize(mat3(inverse_view) * view_direction);
}


bool is_finite_position(vec3 position) {
    return all(lessThan(abs(position), vec3(1000000.0)));
}


bool intersect_waterline(
    vec3 ray_world,
    vec3 camera_position_world,
    float maximum_distance,
    out float hit_distance,
    out vec3 hit_position
) {
    hit_distance = 0.0;
    hit_position = camera_position_world;
    if (
        abs(ray_world.y) <= 0.00001
        || !is_finite_position(ray_world)
    ) {
        return false;
    }

    float candidate_distance = (
        water_level - camera_position_world.y
    ) / ray_world.y;
    for (
        int iteration = 0;
        iteration < MAX_WATERLINE_ITERATIONS;
        iteration++
    ) {
        if (iteration >= waterline_iterations) {
            break;
        }
        vec3 candidate_position = (
            camera_position_world
            + ray_world * candidate_distance
        );
        if (!is_finite_position(candidate_position)) {
            return false;
        }
        float real_height = sample_waterline_height(
            candidate_position.xz
        );
        candidate_distance = (
            real_height - camera_position_world.y
        ) / ray_world.y;
    }

    if (
        candidate_distance <= 0.00001
        || candidate_distance > maximum_distance
    ) {
        return false;
    }
    vec3 candidate_position = (
        camera_position_world + ray_world * candidate_distance
    );
    if (!is_finite_position(candidate_position)) {
        return false;
    }
    hit_distance = candidate_distance;
    hit_position = candidate_position;
    return true;
}


void vertex() {
    // Godot 4.3+ uses reverse-Z: put the full-screen quad on the near plane.
    POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}


void fragment() {
    float raw_depth = texture(depth_texture, SCREEN_UV).x;
    bool is_sky = raw_depth <= 0.000001;
    vec3 ray_world = reconstruct_world_ray(
        SCREEN_UV,
        INV_PROJECTION_MATRIX,
        INV_VIEW_MATRIX
    );
    float scene_distance = underwater_sky_distance;
    vec3 scene_world_position = (
        CAMERA_POSITION_WORLD + ray_world * scene_distance
    );
    if (!is_sky) {
        vec3 view_position = reconstruct_view_position(
            SCREEN_UV,
            raw_depth,
            INV_PROJECTION_MATRIX
        );
        if (is_finite_position(view_position)) {
            scene_distance = length(view_position);
            scene_world_position = view_to_world_position(
                view_position,
                INV_VIEW_MATRIX
            );
        }
    }

    float water_hit_distance = 0.0;
    vec3 water_hit_position = CAMERA_POSITION_WORLD;
    bool water_hit = intersect_waterline(
        ray_world,
        CAMERA_POSITION_WORLD,
        min(scene_distance, underwater_sky_distance),
        water_hit_distance,
        water_hit_position
    );
    float scene_surface_height = sample_waterline_height(
        scene_world_position.xz
    );
    float scene_submerged_depth = (
        scene_surface_height - scene_world_position.y
    );
    float blend_width = max(
        waterline_blend_width,
        fwidth(scene_submerged_depth)
    );
    float macro_height_range = max(
        abs(wave_amplitude_a) + abs(wave_amplitude_b),
        0.001
    );
    float macro_waterline_signal = water_hit
        ? clamp(
            (water_hit_position.y - water_level) / macro_height_range,
            -1.0,
            1.0
        )
        : 0.0;
    float waterline_phase = (
        dot(
            water_hit_position.xz,
            safe_direction(wave_direction_a, vec2(1.0, 0.0))
        ) / max(waterline_distortion_scale, 1.0)
        + simulation_time
            * wave_travel_speed_a
            / max(wave_world_size_a, 0.001)
    ) * TAU_VALUE;
    float waterline_wave_signal = mix(
        macro_waterline_signal,
        sin(waterline_phase),
        0.22
    );
    float waterline_proximity = water_hit
        ? 1.0 - smoothstep(
            blend_width,
            blend_width * 3.0,
            abs(scene_submerged_depth)
        )
        : 0.0;
    float distorted_scene_submerged_depth = (
        scene_submerged_depth
        + waterline_wave_signal
            * waterline_distortion_strength
            * waterline_proximity
    );
    float partial_underwater_mask = water_hit
        ? smoothstep(
            -blend_width,
            blend_width,
            distorted_scene_submerged_depth
        )
        : 0.0;
    float full_submersion_mask = clamp(
        camera_submersion,
        0.0,
        1.0
    );
    float underwater_mask = mix(
        partial_underwater_mask,
        1.0,
        full_submersion_mask
    ) * maximum_effect_strength;
    bool ray_exits_water = (
        camera_depth > 0.0
        && water_hit
        && ray_world.y > 0.0
    );
    float underwater_path_length = water_hit
        ? (
            ray_exits_water
                ? water_hit_distance
                : max(scene_distance - water_hit_distance, 0.0)
        )
        : 0.0;
    float fully_submerged_path_length = ray_exits_water
        ? water_hit_distance
        : scene_distance;
    float water_distance = mix(
        underwater_path_length,
        fully_submerged_path_length,
        full_submersion_mask
    );
    float blur_distance = max(
        water_distance - blur_start_distance,
        0.0
    );
    float blur_factor = 1.0 - exp(
        -blur_density * blur_distance
    );
    float blur_lod = mix(
        blur_near_lod,
        blur_far_lod,
        blur_factor
    );

    vec2 pixel_size = 1.0 / VIEWPORT_SIZE;
    float distance_effect_factor = smoothstep(
        0.0,
        max(near_clarity_distance, 0.001),
        max(water_distance, 0.0)
    );
    float ripple_x = sin(
        SCREEN_UV.y * 74.0 + SCREEN_UV.x * 13.0
        + simulation_time * distortion_speed * 2.1
    );
    float ripple_y = cos(
        SCREEN_UV.x * 67.0 - SCREEN_UV.y * 9.0
        - simulation_time * distortion_speed * 1.7
    );
    vec2 warped_uv = clamp(
        SCREEN_UV
            + vec2(ripple_x, ripple_y)
                * distortion_strength
                * underwater_mask
                * distance_effect_factor
                * (1.0 + blur_factor * 0.25),
        pixel_size,
        vec2(1.0) - pixel_size
    );
    vec3 original_scene_color = textureLod(
        screen_texture,
        SCREEN_UV,
        0.0
    ).rgb;
    vec3 scene_color = textureLod(
        screen_texture,
        warped_uv,
        blur_lod
    ).rgb;
    vec3 transmission = exp(
        -max(absorption_coefficients, vec3(0.0))
            * max(water_distance, 0.0)
    );
    vec3 absorbed_color = scene_color * transmission;
    vec3 tinted_color = mix(
        absorbed_color,
        absorbed_color * underwater_tint.rgb,
        tint_strength * distance_effect_factor
    );
    float distance_contrast = mix(
        1.0,
        contrast,
        distance_effect_factor
    );
    tinted_color = (
        tinted_color - vec3(0.5)
    ) * distance_contrast + vec3(0.5);

    float fog_distance = max(
        water_distance - fog_start_distance,
        0.0
    );
    float sky_fog_amount = min(
        1.0 - exp(
            -sky_fog_density * max(underwater_sky_distance, 0.0)
        ),
        sky_maximum_fog
    );
    float geometry_fog_amount = min(
        1.0 - exp(-fog_density * fog_distance),
        geometry_maximum_fog
    );
    float fog_amount = is_sky
        ? sky_fog_amount
        : geometry_fog_amount;
    vec3 fogged_color = mix(
        tinted_color,
        fog_color.rgb,
        fog_amount
    );
    vec3 underwater_color = mix(
        fogged_color,
        tinted_color,
        minimum_scene_visibility
    );
    float waterline_band = water_hit
        ? 1.0 - smoothstep(
            0.0,
            max(waterline_band_width, 0.001),
            abs(distorted_scene_submerged_depth)
        )
        : 0.0;
    underwater_color += vec3(0.035, 0.075, 0.085)
        * waterline_band
        * waterline_band_strength;
    vec3 final_color = mix(
        original_scene_color,
        underwater_color,
        underwater_mask
    );

    if (debug_mode == 1) {
        ALBEDO = vec3(underwater_mask);
    } else if (debug_mode == 2) {
        ALBEDO = mix(
            original_scene_color,
            vec3(
                clamp(
                    water_distance / max(underwater_sky_distance, 0.001),
                    0.0,
                    1.0
                )
            ),
            underwater_mask
        );
    } else if (debug_mode == 3) {
        ALBEDO = mix(
            original_scene_color,
            vec3(fog_amount),
            underwater_mask
        );
    } else if (debug_mode == 4) {
        ALBEDO = mix(
            original_scene_color,
            transmission,
            underwater_mask
        );
    } else if (debug_mode == 5) {
        ALBEDO = mix(
            original_scene_color,
            vec3(blur_factor),
            underwater_mask
        );
    } else if (debug_mode == 6) {
        ALBEDO = original_scene_color;
    } else if (debug_mode == 7) {
        ALBEDO = mix(
            original_scene_color,
            underwater_color,
            underwater_mask
        );
    } else {
        ALBEDO = final_color;
    }
}
