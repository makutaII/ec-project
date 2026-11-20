// XX claude-terra 13.14 H1 (новый файл)
// Поверхность поля высот шпатлёвки (ATTN_13 §13.14). Сетка плоская: высоту вершины, нормаль и цвет считает шейдер.
// fmap: R пол, G толщина слоя, ю (по узлам окна). tmap: R тип поверхности / 255. Узел окна = узел мировой сетки минус origin.
// Где толщины нет, вершины остаются на полу, а фрагмент отбрасывается. Шум и цвет считаются по мировому индексу узла,
// поэтому не зависят от окна. Те же формулы, что в tests/field_spike (режим GPU).
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D fmap : filter_nearest, repeat_disable;
uniform sampler2D tmap : filter_nearest, repeat_disable;
uniform float step_len = 0.5;
uniform ivec2 origin = ivec2(0, 0);
uniform ivec2 dims = ivec2(17, 17);
uniform float max_h = 16.0;
// Размах шума по типу: гладкая, каменистая, скалистая, ю
uniform vec3 noise_amp = vec3(0.0, 0.12, 0.35);
// Крутизна, с которой цвет типа переходит в цвет скалы, градусы
uniform float rock0 = 40.0;
uniform float rock1 = 55.0;
// Слой тоньше этого не рисуется, ю
uniform float thin_eps = 0.01;

varying vec3 v_col;
varying float v_th;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) * 2.0 - 1.0;
}

// Шум узла (мировой индекс узла) от -1 до 1: две октавы
float node_noise(ivec2 gw) {
	vec2 p = vec2(gw);
	return 0.7 * vnoise(p * 0.45) + 0.3 * vnoise(p * 1.3 + vec2(17.0, 5.0));
}

float amp_of(int t) {
	if (t == 1) {
		return noise_amp.y;
	}
	if (t == 2) {
		return noise_amp.z;
	}
	return noise_amp.x;
}

int type_at(ivec2 g) {
	return int(texelFetch(tmap, g, 0).r * 255.0 + 0.5);
}

// Высота поверхности узла g (индекс в окне): пол плюс слой плюс шум, затухающий к нулевой толщине
float height_at(ivec2 g) {
	ivec2 q = clamp(g, ivec2(0), dims - ivec2(1));
	vec2 fl = texelFetch(fmap, q, 0).rg;
	float th = fl.y;
	float k = smoothstep(0.0, 0.5, th);
	return fl.x + max(th + amp_of(type_at(q)) * node_noise(q + origin) * k, 0.0);
}

void vertex() {
	ivec2 gw = ivec2(floor(vec2(VERTEX.x, VERTEX.z) / step_len + vec2(0.5)));
	ivec2 g = clamp(gw - origin, ivec2(0), dims - ivec2(1));
	int xl = max(g.x - 1, 0);
	int xr = min(g.x + 1, dims.x - 1);
	int zu = max(g.y - 1, 0);
	int zd = min(g.y + 1, dims.y - 1);
	float h = height_at(g);
	float dhx = (height_at(ivec2(xr, g.y)) - height_at(ivec2(xl, g.y))) / (float(xr - xl) * step_len);
	float dhz = (height_at(ivec2(g.x, zd)) - height_at(ivec2(g.x, zu))) / (float(zd - zu) * step_len);
	vec3 n = normalize(vec3(-dhx, 1.0, -dhz));
	VERTEX.y = h;
	NORMAL = n;
	v_th = texelFetch(fmap, g, 0).g;
	int t = type_at(g);
	vec3 base = vec3(0.58, 0.56, 0.53);
	if (t == 0) {
		base = mix(vec3(0.33, 0.58, 0.22), vec3(0.62, 0.61, 0.58), clamp(h / (max_h * 0.6), 0.0, 1.0));
	} else if (t == 1) {
		base = vec3(0.52, 0.5, 0.34);
	}
	float ang = degrees(acos(clamp(n.y, -1.0, 1.0)));
	v_col = mix(base, vec3(0.46, 0.44, 0.42), smoothstep(rock0, rock1, ang));
}

void fragment() {
	if (v_th < thin_eps) {
		discard;
	}
	ALBEDO = v_col;
	ROUGHNESS = 0.95;
}
