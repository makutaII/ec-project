// XX claude-terra 13.14 H1 (новый файл)
// Поверхность поля высот шпатлёвки (ATTN_13 §13.14). Сетка плоская: высоту вершины, нормаль и цвет считает шейдер.
// fmap: R пол, G толщина слоя, ю (по узлам окна). tmap: R тип поверхности (и бит 4 ложа трака) / 255, G слот материала / 255. Узел окна = узел мировой сетки минус origin.
// Где толщины нет, вершины остаются на полу, а фрагмент отбрасывается. Шум высоты считается по мировому индексу узла,
// поэтому не зависит от окна. Те же формулы высоты, что в tests/field_spike (режим GPU).
// H4, H2b: цвет это материалы по слоту узла (texs: массив текстур, tints, tiles на слот): материалы четырёх ближайших узлов с весами
// билинейно (одинаковые сливаются), граница рвётся шумом и заостряется, на крутых склонах цвет уходит в материал слота slot_cliff,
// текстуры мировые (сверху по XZ, на крутом боковые). Класс рельефа узла (шум высоты) от материала не зависит.
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
// Материалы по слотам палитры (FieldMaterials): слой массива текстур, оттенок и размер повтора, ю. Слоёв в массиве может быть меньше 16
uniform sampler2DArray texs : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tints[16] : source_color;
uniform float tiles[16];
// Слот материала крутых склонов
uniform int slot_cliff = 1;
// Рваность границы материалов и частота её шума, 1/ю
uniform float edge_noise = 0.35;
uniform float edge_scale = 2.5;
// Крутизна, с которой материал переходит в материал склонов slot_cliff, градусы
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

// tmap: младшие два бита тип поверхности, бит 4 (значение 4) полоса ложа трака: без шума высоты
int type_raw(ivec2 g) {
	return int(texelFetch(tmap, g, 0).r * 255.0 + 0.5);
}

int type_at(ivec2 g) {
	return type_raw(g) & 3;
}

// Высота поверхности узла g (индекс в окне): пол плюс слой плюс шум, затухающий к нулевой толщине
float height_at(ivec2 g) {
	ivec2 q = clamp(g, ivec2(0), dims - ivec2(1));
	vec2 fl = texelFetch(fmap, q, 0).rg;
	float th = fl.y;
	float k = smoothstep(0.0, 0.5, th);
	int tr = type_raw(q);
	float amp = (tr & 4) != 0 ? 0.0 : amp_of(tr & 3);
	return fl.x + max(th + amp * node_noise(q + origin) * k, 0.0);
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

// Слот материала узла g (индекс в окне)
int mat_slot(ivec2 g) {
	return int(texelFetch(tmap, g, 0).g * 255.0 + 0.5) & 15;
}

// Материалы четырёх ближайших узлов m и их веса w в точке мира: билинейно, узлы без слоя не считаются (иначе их материал натекал бы
// на кромку слоя). Одинаковые материалы сливаются в первый из них
void node_mats(vec2 wxz, out ivec4 m, out vec4 w) {
	vec2 p = wxz / step_len - vec2(origin);
	vec2 fp = floor(p);
	vec2 f = p - fp;
	ivec2 g0 = ivec2(fp);
	vec4 w_all = vec4(0.0);
	vec4 w_th = vec4(0.0);
	float tot = 0.0;
	m = ivec4(0);
	for (int k = 0; k < 4; k++) {
		int ox = k % 2;
		int oy = k / 2;
		ivec2 g = clamp(g0 + ivec2(ox, oy), ivec2(0), dims - ivec2(1));
		float bw = (ox == 1 ? f.x : 1.0 - f.x) * (oy == 1 ? f.y : 1.0 - f.y);
		m[k] = mat_slot(g);
		w_all[k] = bw;
		if (texelFetch(fmap, g, 0).g >= thin_eps) {
			w_th[k] = bw;
			tot += bw;
		}
	}
	w = tot < 0.0001 ? w_all : w_th / tot;
	for (int k = 1; k < 4; k++) {
		for (int j = 0; j < 3; j++) {
			if (j < k && m[j] == m[k] && w[k] > 0.0) {
				w[j] += w[k];
				w[k] = 0.0;
				break;
			}
		}
	}
}

// Граница рвётся шумом (только там, где вес между 0 и 1) и заостряется: вместо клетчатого градиента неровный край.
// Шум зависит от материала, а не от места узла среди четырёх, поэтому край непрерывен на границах ячеек
vec4 sharpen(vec4 w, ivec4 m, vec2 wxz) {
	vec4 r = w;
	for (int c = 0; c < 4; c++) {
		float fm = float(m[c]);
		float n = vnoise(wxz * edge_scale + vec2(fm * 13.1, fm * 7.7));
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
	return texture(texs, vec3(uv, float(c))).rgb * tints[c].rgb;
}

// Цвет материала слота c в точке: сверху проекция по XZ, на крутом склоне боковые проекции XY и ZY.
// Ветвлений по данным нет (все выборки идут при любых значениях): иначе производные для мип-уровней в ветвях не определены
vec3 mat_color(int c, vec3 p, vec3 n) {
	float tl = max(tiles[c], 0.1);
	vec3 top = tex_of(c, p.xz / tl);
	float wy = smoothstep(0.6, 0.9, abs(n.y));
	float wx = abs(n.x);
	float wz = abs(n.z);
	vec3 side = (tex_of(c, p.zy / tl) * wx + tex_of(c, p.xy / tl) * wz) / max(wx + wz, 0.0001);
	return mix(side, top, wy);
}

void fragment() {
	vec3 n = normalize(v_nrm);
	ivec4 m;
	vec4 w;
	node_mats(v_pos.xz, m, w);
	w = sharpen(w, m, v_pos.xz);
	vec3 col = vec3(0.0);
	for (int c = 0; c < 4; c++) {
		col += w[c] * mat_color(m[c], v_pos, n);
	}
	// крутой склон уходит в материал склонов
	col = mix(col, mat_color(slot_cliff, v_pos, n), v_slope);
	// крупная вариация яркости прячет повтор текстуры
	col *= 0.92 + 0.08 * vnoise(v_pos.xz * 0.12);
	ALBEDO = col;
	ROUGHNESS = 0.95;
	if (v_th < thin_eps) {
		discard;
	}
}
