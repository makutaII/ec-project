// XX claude-terra 13.14 H1 (новый файл)
// Поверхность поля высот шпатлёвки (ATTN_13 §13.14). Сетка плоская: высоту вершины, нормаль и цвет считает шейдер.
// fmap: R пол, G толщина слоя, ю (по узлам окна). tmap: R тип поверхности / 255. Узел окна = узел мировой сетки минус origin.
// Где толщины нет, вершины остаются на полу, а фрагмент отбрасывается. Шум высоты считается по мировому индексу узла,
// поэтому не зависит от окна. Те же формулы высоты, что в tests/field_spike (режим GPU).
// H4: цвет это материалы по типу узла (tex0..tex3, tint0..tint3, tile): веса четырёх ближайших узлов билинейно, граница
// рвётся шумом и заостряется, на крутых склонах веса уходят в скалистый канал, текстуры мировые (сверху по XZ, на крутом боковые).
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
// Материалы каналов (0 гладкая, 1 каменистая, 2 скалистая, 3 запас). Без текстуры канал рисуется цветом tint
uniform sampler2D tex0 : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex1 : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex2 : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex3 : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint0 : source_color = vec4(0.5, 0.78, 0.34, 1.0);
uniform vec4 tint1 : source_color = vec4(0.92, 0.86, 0.7, 1.0);
uniform vec4 tint2 : source_color = vec4(0.66, 0.64, 0.61, 1.0);
uniform vec4 tint3 : source_color = vec4(0.82, 0.74, 0.5, 1.0);
// Размер повтора текстуры каждого канала, ю
uniform vec4 tile = vec4(3.0, 2.5, 5.0, 3.0);
// Рваность границы материалов и частота её шума, 1/ю
uniform float edge_noise = 0.35;
uniform float edge_scale = 2.5;
// Крутизна, с которой материал переходит в скалистый, градусы
uniform float rock0 = 40.0;
uniform float rock1 = 55.0;
// Слой тоньше этого не рисуется, ю
uniform float thin_eps = 0.01;

varying vec3 v_pos;
varying vec3 v_nrm;
varying float v_slope;
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
	v_pos = vec3(VERTEX.x, h, VERTEX.z);
	v_nrm = n;
	float ang = degrees(acos(clamp(n.y, -1.0, 1.0)));
	v_slope = smoothstep(rock0, rock1, ang);
}

vec4 onehot(int t) {
	if (t == 0) {
		return vec4(1.0, 0.0, 0.0, 0.0);
	}
	if (t == 1) {
		return vec4(0.0, 1.0, 0.0, 0.0);
	}
	if (t == 2) {
		return vec4(0.0, 0.0, 1.0, 0.0);
	}
	return vec4(0.0, 0.0, 0.0, 1.0);
}

// Веса каналов в точке мира: билинейно по четырём узлам, узлы без слоя не считаются (иначе их тип 0 натекал бы на кромку слоя)
vec4 channel_weights(vec2 wxz) {
	vec2 p = wxz / step_len - vec2(origin);
	vec2 fp = floor(p);
	vec2 f = p - fp;
	ivec2 g0 = ivec2(fp);
	vec4 w = vec4(0.0);
	vec4 w_all = vec4(0.0);
	float tot = 0.0;
	for (int k = 0; k < 4; k++) {
		int ox = k % 2;
		int oy = k / 2;
		ivec2 g = clamp(g0 + ivec2(ox, oy), ivec2(0), dims - ivec2(1));
		float bw = (ox == 1 ? f.x : 1.0 - f.x) * (oy == 1 ? f.y : 1.0 - f.y);
		vec4 oh = onehot(clamp(type_at(g), 0, 3));
		w_all += oh * bw;
		if (texelFetch(fmap, g, 0).g >= thin_eps) {
			w += oh * bw;
			tot += bw;
		}
	}
	if (tot < 0.0001) {
		return w_all;
	}
	return w / tot;
}

// Граница рвётся шумом (только там, где вес между 0 и 1) и заостряется: вместо клетчатого градиента неровный край
vec4 sharpen(vec4 w, vec2 wxz) {
	vec4 r = w;
	for (int c = 0; c < 4; c++) {
		float n = vnoise(wxz * edge_scale + vec2(float(c) * 13.1, float(c) * 7.7));
		float v = w[c];
		v = clamp(v + edge_noise * n * 4.0 * v * (1.0 - v), 0.0, 1.0);
		r[c] = smoothstep(0.3, 0.7, v);
	}
	float s = r.x + r.y + r.z + r.w;
	if (s < 0.0001) {
		return w;
	}
	return r / s;
}

vec3 tex_of(int c, vec2 uv) {
	if (c == 0) {
		return texture(tex0, uv).rgb * tint0.rgb;
	}
	if (c == 1) {
		return texture(tex1, uv).rgb * tint1.rgb;
	}
	if (c == 2) {
		return texture(tex2, uv).rgb * tint2.rgb;
	}
	return texture(tex3, uv).rgb * tint3.rgb;
}

// Цвет канала в точке: сверху проекция по XZ, на крутом склоне боковые проекции XY и ZY.
// Ветвлений по данным нет (все выборки идут при любых значениях): иначе производные для мип-уровней в ветвях не определены
vec3 mat_color(int c, vec3 p, vec3 n) {
	float tl = max(tile[c], 0.1);
	vec3 top = tex_of(c, p.xz / tl);
	float wy = smoothstep(0.6, 0.9, abs(n.y));
	float wx = abs(n.x);
	float wz = abs(n.z);
	vec3 side = (tex_of(c, p.zy / tl) * wx + tex_of(c, p.xy / tl) * wz) / max(wx + wz, 0.0001);
	return mix(side, top, wy);
}

void fragment() {
	vec3 n = normalize(v_nrm);
	vec4 w = sharpen(channel_weights(v_pos.xz), v_pos.xz);
	// крутой склон уходит в скалистый канал
	w = mix(w, vec4(0.0, 0.0, 1.0, 0.0), v_slope);
	vec3 col = vec3(0.0);
	for (int c = 0; c < 4; c++) {
		col += w[c] * mat_color(c, v_pos, n);
	}
	// крупная вариация яркости прячет повтор текстуры
	col *= 0.92 + 0.08 * vnoise(v_pos.xz * 0.12);
	ALBEDO = col;
	ROUGHNESS = 0.95;
	if (v_th < thin_eps) {
		discard;
	}
}
