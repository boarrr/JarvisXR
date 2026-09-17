shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;
uniform float activity = 0.0;
uniform float clock_time = 0.0;

float ring(float r, float radius, float width) {
	return 1.0 - smoothstep(width, width + fwidth(r) * 1.5, abs(r - radius));
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float sweep = pow(max(0.0, cos(a - clock_time * 0.35)), 28.0);
	float sectors = step(0.15, fract(a * 12.0 / 6.28318 + clock_time * 0.012));
	float ticks = step(0.84, fract(a * 96.0 / 6.28318));
	float lines = ring(r, 0.9, 0.0015) * 0.4 + ring(r, 0.76, 0.002) * 0.55;
	lines += ring(r, 0.81, 0.017) * ticks * 0.5;
	lines += ring(r, 0.61, 0.014) * sectors * (0.3 + sweep);
	lines += ring(r, 0.35, 0.003) * 0.7 + ring(r, 0.31, 0.002) * 0.4;
	float pulse = fract(clock_time * 0.12);
	lines += ring(r, 0.35 + pulse * 0.55, 0.002) * (1.0 - pulse) * activity * 0.5;
	vec3 tint = mix(vec3(0.025, 0.56, 0.72), vec3(0.1, 0.95, 0.8), sweep * 0.5);
	ALBEDO = tint;
	EMISSION = tint * lines;
	ALPHA = clamp(lines * (0.5 + activity * 0.3), 0.0, 0.8);
}
