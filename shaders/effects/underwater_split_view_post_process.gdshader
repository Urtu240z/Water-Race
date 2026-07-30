shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

uniform float camera_submersion : hint_range(0.0, 1.0) = 0.0;
uniform vec4 underwater_tint : source_color = vec4(0.10, 0.40, 0.50, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.16;
uniform float contrast : hint_range(0.25, 1.5) = 0.94;
uniform vec4 fog_tint : source_color = vec4(0.10, 0.40, 0.50, 1.0);
uniform float fog_density : hint_range(0.0, 0.1, 0.001) = 0.009;
uniform float sky_fog_density : hint_range(0.0, 0.1, 0.001) = 0.007;
uniform float sky_maximum_fog : hint_range(0.0, 1.0, 0.01) = 0.72;
uniform float geometry_maximum_fog : hint_range(0.0, 1.0, 0.01) = 0.88;
uniform vec3 absorption_coefficients = vec3(0.022, 0.010, 0.005);
uniform float minimum_scene_visibility : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float near_clarity_distance : hint_range(0.0, 30.0, 0.5) = 7.0;
uniform float fog_start_distance : hint_range(0.0, 50.0, 0.5) = 5.0;
uniform float distortion_strength : hint_range(0.0, 0.01) = 0.0008;
uniform float distortion_speed : hint_range(0.0, 5.0) = 0.7;
uniform float maximum_effect_strength : hint_range(0.0, 1.0) = 1.0;
uniform float blur_strength : hint_range(0.0, 24.0, 0.1) = 6.0;
uniform float underwater_visibility_radius : hint_range(5.0, 300.0, 1.0) = 80.0;
uniform float underwater_visibility_blend : hint_range(1.0, 150.0, 1.0) = 20.0;
uniform int debug_mode : hint_range(0, 7, 1) = 0;


vec3 reconstruct_view_position(
    vec2 screen_uv,
    float raw_depth,
    mat4 inverse_projection
) {
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


bool is_finite_position(vec3 position) {
    return all(lessThan(abs(position), vec3(1000000.0)));
}


vec3 sample_camera_blur(
    vec2 screen_uv,
    vec2 pixel_size,
    float radius_pixels
) {
    float safe_radius = max(radius_pixels, 0.0);
    vec3 sharp_color = textureLod(screen_texture, screen_uv, 0.0).rgb;
    if (safe_radius <= 0.001) {
        return sharp_color;
    }

    // Sample the already composed camera buffer. The mip level provides the
    // broad blur, while the surrounding taps keep the result smooth and make
    // the blur cross object silhouettes instead of softening textures locally.
    float blur_lod = clamp(log2(safe_radius + 1.0), 0.0, 5.0);
    vec2 spread = pixel_size * safe_radius * 0.5;
    vec3 blurred_color = textureLod(
        screen_texture,
        screen_uv,
        blur_lod
    ).rgb * 0.36;
    blurred_color += textureLod(
        screen_texture,
        clamp(screen_uv + vec2(spread.x, 0.0), pixel_size, vec2(1.0) - pixel_size),
        blur_lod
    ).rgb * 0.16;
    blurred_color += textureLod(
        screen_texture,
        clamp(screen_uv - vec2(spread.x, 0.0), pixel_size, vec2(1.0) - pixel_size),
        blur_lod
    ).rgb * 0.16;
    blurred_color += textureLod(
        screen_texture,
        clamp(screen_uv + vec2(0.0, spread.y), pixel_size, vec2(1.0) - pixel_size),
        blur_lod
    ).rgb * 0.16;
    blurred_color += textureLod(
        screen_texture,
        clamp(screen_uv - vec2(0.0, spread.y), pixel_size, vec2(1.0) - pixel_size),
        blur_lod
    ).rgb * 0.16;
    return mix(
        sharp_color,
        blurred_color,
        smoothstep(0.0, 1.0, safe_radius)
    );
}


void vertex() {
    POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}


void fragment() {
    float safe_visibility_radius = max(underwater_visibility_radius, 0.001);
    float safe_visibility_blend = clamp(
        underwater_visibility_blend,
        0.001,
        safe_visibility_radius
    );
    float raw_depth = texture(depth_texture, SCREEN_UV).x;
    bool is_sky = raw_depth <= 0.000001;
    float scene_distance = safe_visibility_radius;
    if (!is_sky) {
        vec3 view_position = reconstruct_view_position(
            SCREEN_UV,
            raw_depth,
            INV_PROJECTION_MATRIX
        );
        if (is_finite_position(view_position)) {
            scene_distance = length(view_position);
        }
    }

    float underwater_mask = clamp(
        camera_submersion,
        0.0,
        1.0
    ) * maximum_effect_strength;
    float water_distance = max(scene_distance, 0.0);
    vec2 pixel_size = 1.0 / VIEWPORT_SIZE;
    float distance_effect_factor = smoothstep(
        0.0,
        max(near_clarity_distance, 0.001),
        water_distance
    );
    float ripple_x = sin(
        SCREEN_UV.y * 74.0 + SCREEN_UV.x * 13.0
        + TIME * distortion_speed * 2.1
    );
    float ripple_y = cos(
        SCREEN_UV.x * 67.0 - SCREEN_UV.y * 9.0
        - TIME * distortion_speed * 1.7
    );
    vec2 warped_uv = clamp(
        SCREEN_UV
            + vec2(ripple_x, ripple_y)
                * distortion_strength
                * underwater_mask
                * distance_effect_factor,
        pixel_size,
        vec2(1.0) - pixel_size
    );
    vec3 original_scene_color = textureLod(
        screen_texture,
        SCREEN_UV,
        0.0
    ).rgb;
    vec3 scene_color = sample_camera_blur(
        warped_uv,
        pixel_size,
        blur_strength * underwater_mask
    );
    vec3 transmission = exp(
        -max(absorption_coefficients, vec3(0.0)) * water_distance
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
    tinted_color = max(tinted_color, vec3(0.0));

    float fog_distance = max(
        water_distance - fog_start_distance,
        0.0
    );
    float base_fog_amount = is_sky
        ? min(
            1.0 - exp(-sky_fog_density * safe_visibility_radius),
            sky_maximum_fog
        )
        : min(
            1.0 - exp(-fog_density * fog_distance),
            geometry_maximum_fog
        );
    float radius_extinction = smoothstep(
        safe_visibility_radius - safe_visibility_blend,
        safe_visibility_radius,
        water_distance
    );
    float fog_amount = max(base_fog_amount, radius_extinction);
    vec3 fogged_color = mix(
        tinted_color,
        fog_tint.rgb,
        fog_amount
    );
    float preserved_visibility = minimum_scene_visibility
        * (1.0 - radius_extinction);
    vec3 underwater_color = mix(
        fogged_color,
        tinted_color,
        preserved_visibility
    );
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
            vec3(clamp(water_distance / safe_visibility_radius, 0.0, 1.0)),
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
            vec3(clamp(blur_strength / 24.0, 0.0, 1.0)),
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
