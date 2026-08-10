float event_wave_smooth(float value) { float t = clamp(value, 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
// x is height; yz are analytic XZ derivatives. CPU uses the same sech² ridge.
vec3 sample_event_wave_state(vec2 logical_xz) {
	vec3 result = vec3(0.0);
	for (int i = 0; i < MAX_EVENT_WAVES; i++) {
		if (event_wave_active[i] == 0) continue;
		float age = simulation_time - event_wave_start_times[i];
		float life = event_wave_lifetimes[i]; if (age < 0.0 || (life > 0.0 && age >= life)) continue;
		float fade = event_wave_fade_ins[i] > 0.0 ? event_wave_smooth(age / event_wave_fade_ins[i]) : 1.0;
		if (life > 0.0 && event_wave_fade_outs[i] > 0.0) fade *= 1.0 - event_wave_smooth((age - (life - event_wave_fade_outs[i])) / event_wave_fade_outs[i]);
		vec2 d = normalize(event_wave_directions[i]); vec2 crest = event_wave_origins[i] + d * event_wave_speeds[i] * age;
		float s = dot(logical_xz - crest, d); float w = max(event_wave_widths[i], 0.001); float t = tanh(s / w); float shape = 1.0 - t * t;
		float h = event_wave_amplitudes[i] * shape; float deriv = event_wave_amplitudes[i] * (-2.0 * t * shape / w);
		if (event_wave_trough_amplitudes[i] > 0.0) { float tw = max(event_wave_trough_widths[i], 0.001); float tt = tanh((s + event_wave_trough_offsets[i]) / tw); float ts = 1.0 - tt * tt; h -= event_wave_trough_amplitudes[i] * ts; deriv += event_wave_trough_amplitudes[i] * 2.0 * tt * ts / tw; }
		result += vec3(h, d * deriv) * clamp(fade, 0.0, 1.0);
	}
	return result;
}
