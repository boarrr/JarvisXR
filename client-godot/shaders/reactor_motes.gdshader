shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;
uniform float clock_time = 0.0;
uniform float activity = 0.0;
varying float luminance;

void vertex() {
	float phase = INSTANCE_CUSTOM.x * 6.283185;
	float speed = 0.012 + INSTANCE_CUSTOM.y * 0.035;
	float angle = phase + clock_time * speed;
	float radius = 3.4 + INSTANCE_CUSTOM.z * 2.0;
	vec3 center = vec3(sin(angle) * radius, 0.12 + INSTANCE_CUSTOM.w * 3.5, cos(angle) * radius);
	center.y += sin(clock_time * 0.25 + phase * 4.0) * 0.04;
	vec3 corner = INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y;
	VERTEX = center + corner;
	luminance = 0.13 + 0.2 * pow(max(0.0, sin(phase + clock_time * 0.6)), 4.0) + activity * 0.1;
}

void fragment() {
	float dot_shape = 1.0 - smoothstep(0.1, 0.5, length(UV - 0.5));
	ALBEDO = vec3(0.07, 0.65, 0.85);
	EMISSION = ALBEDO * 1.5;
	ALPHA = dot_shape * luminance;
}
