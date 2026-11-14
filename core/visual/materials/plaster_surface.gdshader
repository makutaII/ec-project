shader_type spatial;

// XX claude-terra 13.13 K3 (новый файл)
// Материал оболочки гипсового бинта (ATTN_13 §13.13): основа стадии листа, поверх неё краска кистей по ячейкам.
// Краска это сплэт-текстура по миру (r трава, g скала, b гравий, a запас), 2 пикселя на ячейку (PaintSplat).
// Классы смешиваются трипланарно, граница мазка рваная от шума (без квадратов ячеек). Скала слоится по высоте.
// Где краски нет (или сплэта нет, splat_rect.z = 0), виден только материал основы.

uniform sampler2D base_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 base_color : source_color = vec4(1.0);
uniform float base_scale = 0.15;

uniform sampler2D splat : filter_linear, repeat_disable;
// x0, z0, ширина, глубина сплэта в мире; ширина 0 = краски нет
uniform vec4 splat_rect = vec4(0.0);
// K3c. Полклетки краски, ю: у стенки краска берётся на столько внутрь листа (стенка красится от края верха)
uniform float splat_shift = 0.0;

uniform sampler2D edge_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D grass_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D gravel_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 grass_color : source_color = vec4(0.33, 0.58, 0.22, 1.0);
uniform vec4 rock_color : source_color = vec4(0.52, 0.51, 0.5, 1.0);
uniform vec4 gravel_color : source_color = vec4(0.78, 0.68, 0.5, 1.0);
uniform float grass_scale = 0.35;
uniform float rock_scale = 0.18;
uniform float gravel_scale = 0.9;
// высота слоя породы у скалы, ю
uniform float rock_layer_height = 0.8;

varying vec3 w_pos;
varying vec3 w_nrm;

vec3 tri(sampler2D t, vec3 p, vec3 n, float sc) {
	vec3 b = pow(abs(n), vec3(4.0));
	b /= (b.x + b.y + b.z + 1e-5);
	vec3 x = texture(t, p.zy * sc).rgb;
	vec3 y = texture(t, p.xz * sc).rgb;
	vec3 z = texture(t, p.xy * sc).rgb;
	return x * b.x + y * b.y + z * b.z;
}

float hash11(float x) {
	return fract(sin(x * 127.1) * 43758.5453);
}

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	w_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 n = normalize(w_nrm);
	vec3 col = base_color.rgb * tri(base_tex, w_pos, n, base_scale);

	if (splat_rect.z > 0.0) {
		// стенка (нормаль почти горизонтальна): точка краски сдвигается внутрь листа, на плоскости и пандусе сдвига нет
		float wall = 1.0 - smoothstep(0.25, 0.6, abs(n.y));
		vec2 suv = (w_pos.xz - n.xz * wall * splat_shift - splat_rect.xy) / splat_rect.zw;
		if (suv.x >= 0.0 && suv.y >= 0.0 && suv.x <= 1.0 && suv.y <= 1.0) {
			vec3 cw = texture(splat, suv).rgb;
			float total = cw.r + cw.g + cw.b;
			if (total > 0.02) {
				float n1 = tri(edge_noise, w_pos, n, 0.7).r;
				float n2 = tri(edge_noise, w_pos + vec3(17.3, 5.1, 9.7), n, 1.9).r;
				// рваная граница мазка: порог покрытия сдвигается шумом
				float cover = smoothstep(0.38, 0.62, total + (n1 - 0.5) * 0.55 + (n2 - 0.5) * 0.25);
				if (cover > 0.001) {
					// соседние классы делят ячейку не ровным градиентом, а пятнами
					vec3 s = cw + (vec3(n1, n2, fract(n1 * 3.7 + n2 * 2.3)) - 0.5) * 0.3;
					float mx = max(max(s.r, s.g), s.b);
					vec3 q = clamp((s - (mx - 0.18)) / 0.18, 0.0, 1.0) * step(0.001, cw);
					q /= (q.r + q.g + q.b + 1e-5);
					vec3 painted = vec3(0.0);
					if (q.r > 0.0) {
						painted += q.r * grass_color.rgb * tri(grass_tex, w_pos, n, grass_scale);
					}
					if (q.g > 0.0) {
						float layer = floor(w_pos.y / rock_layer_height + n1 * 0.15);
						float band = mix(0.78, 1.12, hash11(layer));
						painted += q.g * rock_color.rgb * band * tri(rock_tex, w_pos, n, rock_scale);
					}
					if (q.b > 0.0) {
						painted += q.b * gravel_color.rgb * tri(gravel_tex, w_pos, n, gravel_scale);
					}
					col = mix(col, painted, cover);
				}
			}
		}
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
}
