shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

const int MAX_RIPPLES = 12;
const float TAU_VALUE = 6.28318530718;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
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
uniform vec4 underwater_tint : source_color = vec4(0.18, 0.58, 0.68, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.24;
uniform float contrast : hint_range(0.25, 1.5) = 0.86;
uniform vec4 fog_color : source_color = vec4(0.025, 0.22, 0.29, 1.0);
uniform float fog_density : hint_range(0.0, 0.5) = 0.0325;
uniform float absorption_density : hint_range(0.0, 0.5) = 0.055;
uniform float distortion_strength : hint_range(0.0, 0.01) = 0.0014;
uniform float distortion_speed : hint_range(0.0, 5.0) = 0.7;
uniform float waterline_blend_width : hint_range(0.01, 1.0) = 0.12;
uniform float maximum_effect_strength : hint_range(0.0, 1.0) = 1.0;
uniform bool debug_mask_enabled = false;


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


float sample_surface_height(vec2 world_xz) {
    if (!ocean_enabled) {
        return water_level;
    }
    vec2 logical_xz = world_xz + ocean_logical_origin_offset_xz;
    return water_level
        + sample_macro_height(logical_xz)
        + sample_ripple_height(logical_xz);
}


void vertex() {
    // Godot 4.3+ uses reverse-Z: put the full-screen quad on the near plane.
    POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}


void fragment() {
    float raw_depth = texture(depth_texture, SCREEN_UV).x;
    bool is_sky = raw_depth <= 0.000001;
    float underwater_mask = 1.0;
    float scene_distance = max(camera_depth, 0.0);
    float submerged_distance = max(camera_depth, 0.0);

    if (!is_sky) {
        vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
        vec4 view_position = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
        view_position.xyz /= view_position.w;
        vec3 world_position = (
            INV_VIEW_MATRIX * vec4(view_position.xyz, 1.0)
        ).xyz;
        float surface_height = sample_surface_height(world_position.xz);
        submerged_distance = surface_height - world_position.y;
        underwater_mask = smoothstep(
            -waterline_blend_width,
            waterline_blend_width,
            submerged_distance
        );
        scene_distance = length(view_position.xyz);
    }

    // Surface reconstruction only shapes the effect after the camera crosses it.
    underwater_mask *= camera_submersion * maximum_effect_strength;
    vec2 pixel_size = 1.0 / VIEWPORT_SIZE;
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
            + vec2(ripple_x, ripple_y) * distortion_strength * underwater_mask,
        pixel_size,
        vec2(1.0) - pixel_size
    );
    vec3 scene_color = texture(screen_texture, warped_uv).rgb;
    vec3 tinted_color = mix(
        scene_color,
        scene_color * underwater_tint.rgb,
        tint_strength
    );
    float luminance = dot(tinted_color, vec3(0.2126, 0.7152, 0.0722));
    tinted_color = mix(vec3(luminance), tinted_color, contrast);

    float water_distance = mix(
        max(submerged_distance, 0.0),
        scene_distance,
        camera_submersion
    );
    float absorption = 1.0 - exp(
        -absorption_density * max(water_distance, 0.0)
    );
    float fog_amount = 1.0 - exp(
        -fog_density * max(water_distance, 0.0)
    );
    tinted_color = mix(
        tinted_color,
        tinted_color * vec3(0.52, 0.88, 0.92),
        absorption * 0.55
    );
    tinted_color = mix(tinted_color, fog_color.rgb, fog_amount);
    ALBEDO = debug_mask_enabled
        ? vec3(underwater_mask)
        : mix(scene_color, tinted_color, underwater_mask);
}
