shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never;

uniform vec4 tint : source_color = vec4(0.03, 0.85, 1.0, 1.0);
uniform float surface_opacity = 0.7;
uniform float activity = 0.2;
uniform bool shell = false;

void fragment() {
	float facing = clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0);
	float rim = pow(1.0 - facing, 2.8);
	vec2 grid = UV * vec2(24.0, 14.0);
	vec2 width = max(fwidth(grid), vec2(0.001));
	vec2 cell = abs(fract(grid - 0.5) - 0.5) / width;
	float lattice = 1.0 - min(min(cell.x, cell.y), 1.0);
	float scan = pow(max(0.0, cos(UV.y * 6.28318 - TIME * (0.6 + activity))), 18.0);
	float energy = shell ? (rim * 0.65 + lattice * 0.13 + scan * 0.1) :
		(0.18 + facing * 0.26 + rim * 0.9 + scan * 0.24);
	ALBEDO = tint.rgb;
	EMISSION = tint.rgb * energy * 1.4 + vec3(0.2, 0.5, 0.5) * rim * 0.15;
	ALPHA = clamp(energy * surface_opacity, 0.0, 0.95);
}
