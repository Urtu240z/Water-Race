shader_type fog;


uniform float water_level
    : hint_range(-100.0, 100.0, 0.01) = -1.02;

uniform float mist_density
    : hint_range(0.0, 0.5, 0.005) = 0.10;

uniform float mist_opacity
    : hint_range(0.0, 1.0, 0.01) = 0.0;

uniform vec4 mist_color : source_color =
    vec4(0.56, 0.64, 0.70, 1.0);

uniform float mist_height
    : hint_range(0.05, 2.0, 0.01) = 0.75;

uniform float mist_height_noise_strength
    : hint_range(0.0, 1.5, 0.01) = 0.25;

uniform float mist_height_falloff
    : hint_range(0.1, 4.0, 0.01) = 1.60;

uniform float mist_noise_scale
    : hint_range(0.1, 30.0, 0.1) = 6.0;

uniform float mist_detail_scale
    : hint_range(0.1, 50.0, 0.1) = 16.0;

uniform float mist_wind_speed
    : hint_range(0.0, 4.0, 0.05) = 0.25;

uniform vec2 mist_wind_direction =
    vec2(0.92, 0.38);


float mist_hash13(vec3 value) {
    value = fract(value * 0.1031);

    value += dot(
        value,
        value.yzx + 33.33
    );

    return fract(
        (value.x + value.y) * value.z
    );
}


float mist_value_noise(vec3 value) {
    vec3 cell = floor(value);
    vec3 local_position = fract(value);

    local_position = (
        local_position
        * local_position
        * (3.0 - 2.0 * local_position)
    );

    float n000 = mist_hash13(
        cell + vec3(0.0, 0.0, 0.0)
    );
    float n100 = mist_hash13(
        cell + vec3(1.0, 0.0, 0.0)
    );
    float n010 = mist_hash13(
        cell + vec3(0.0, 1.0, 0.0)
    );
    float n110 = mist_hash13(
        cell + vec3(1.0, 1.0, 0.0)
    );
    float n001 = mist_hash13(
        cell + vec3(0.0, 0.0, 1.0)
    );
    float n101 = mist_hash13(
        cell + vec3(1.0, 0.0, 1.0)
    );
    float n011 = mist_hash13(
        cell + vec3(0.0, 1.0, 1.0)
    );
    float n111 = mist_hash13(
        cell + vec3(1.0, 1.0, 1.0)
    );

    float x00 = mix(
        n000,
        n100,
        local_position.x
    );
    float x10 = mix(
        n010,
        n110,
        local_position.x
    );
    float x01 = mix(
        n001,
        n101,
        local_position.x
    );
    float x11 = mix(
        n011,
        n111,
        local_position.x
    );

    float y0 = mix(
        x00,
        x10,
        local_position.y
    );
    float y1 = mix(
        x01,
        x11,
        local_position.y
    );

    return mix(
        y0,
        y1,
        local_position.z
    );
}


float mist_fbm(vec3 value) {
    float result = 0.0;
    float amplitude = 0.57;

    result += mist_value_noise(value)
        * amplitude;

    value = (
        value * 2.03
        + vec3(17.13, 7.71, 11.37)
    );

    amplitude *= 0.50;

    result += mist_value_noise(value)
        * amplitude;

    value = (
        value * 2.11
        + vec3(-9.17, 13.91, 5.73)
    );

    amplitude *= 0.50;

    result += mist_value_noise(value)
        * amplitude;

    return result;
}


void fog() {
    vec2 wind = mist_wind_direction;

    if (length(wind) <= 0.0001) {
        wind = vec2(1.0, 0.0);
    } else {
        wind = normalize(wind);
    }

    vec3 sample_position = (
        WORLD_POSITION
        + vec3(
            wind.x,
            0.0,
            wind.y
        ) * TIME * mist_wind_speed
    );

    float safe_mass_scale = max(
        mist_noise_scale,
        0.05
    );

    float safe_detail_scale = max(
        mist_detail_scale,
        0.05
    );

    float mass_noise = mist_fbm(
        vec3(
            sample_position.x
                / safe_mass_scale,
            sample_position.y
                / max(
                    safe_mass_scale * 0.65,
                    0.05
                ),
            sample_position.z
                / safe_mass_scale
        )
    );

    float detail_noise = mist_value_noise(
        sample_position
            / safe_detail_scale
        + vec3(19.17, 7.31, -13.73)
    );

    float combined_noise = clamp(
        mass_noise * 0.78
        + detail_noise * 0.22,
        0.0,
        1.0
    );

    float height_above_water = (
        WORLD_POSITION.y - water_level
    );

    float irregular_height = max(
        mist_height
        + (
            combined_noise - 0.5
        ) * 2.0
            * mist_height_noise_strength,
        0.05
    );

    float bottom_mask = smoothstep(
        -0.08,
        0.06,
        height_above_water
    );

    float top_mask = (
        1.0
        - smoothstep(
            irregular_height * 0.42,
            irregular_height,
            height_above_water
        )
    );

    float mass_mask = smoothstep(
        0.43,
        0.72,
        combined_noise
    );

    float fragmented_density = mix(
        0.01,
        1.0,
        mass_mask
    );

    float height_mask = pow(
        clamp(
            bottom_mask * top_mask,
            0.0,
            1.0
        ),
        max(
            mist_height_falloff,
            0.01
        )
    );

    DENSITY = max(
        mist_density
        * mist_opacity
        * fragmented_density
        * height_mask,
        0.0
    );

    ALBEDO = mist_color.rgb;
    EMISSION = vec3(0.0);
}
