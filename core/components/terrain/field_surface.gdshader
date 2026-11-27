// XX claude-terra 13.14 H1 (новый файл)
// Поверхность поля высот шпатлёвки (ATTN_13 §13.14). Сетка плоская: высоту вершины, нормаль и цвет считает шейдер.
// fmap: R пол, G толщина слоя, ю (по узлам окна). tmap (RGBA8): R тип поверхности (и бит 4 ложа трака), G слот верхнего (младшие 4 бита) и нижнего (старшие) материала, B прозрачность верхнего (младшие 4 бита, 0 непрозрачный) и ширина перехода (старшие), A есть слой (255) или нет. Узел окна = узел мировой сетки минус origin.
// Где толщины нет, вершины остаются на полу, а фрагмент отбрасывается. Шум высоты считается по мировому индексу узла,
// поэтому не зависит от окна. Те же формулы высоты, что в tests/field_spike (режим GPU).
// H4, H2b: цвет это материалы по слоту узла (texs: массив текстур, tints, tiles на слот): материалы четырёх ближайших узлов с весами
// билинейно (одинаковые сливаются), граница рвётся шумом и заостряется, на крутых склонах цвет уходит в материал слота slot_cliff,
// текстуры мировые (сверху по XZ, на крутом боковые). Класс рельефа узла (шум высоты) от материала не зависит.
// H2c: каждый узел это два материала (верхний с долей 1 - прозрачность и нижний) и своя ширина перехода. Вес узла в точке это
// треугольное окно радиуса 1 ячейка + ширина перехода узла (до KR - 1 ячеек), поэтому узкий переход остаётся как раньше (около одной
// ячейки), а широкий размывается на 1 ю. Окно (2 * KR)^2 узлов, из 16 слотов берутся четыре самых весомых.
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
// Ширина перехода, которой соответствует значение 15 в узле, ю (FieldSurface.BLEND_MAX)
uniform float blend_max = 1.0;
// Радиус окна выборки узлов вокруг точки, узлов: окно (2 * KR)^2. Предел ширины перехода (KR - 1) ячеек
const int KR = 3;
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

// Четыре самых весомых материала точки m и их веса w (сумма 1), средняя ширина перехода bl (0..1) вокруг точки.
// Каждый узел окна даёт два вклада: верхний материал с долей 1 - прозрачность и нижний с остальным; узлы без слоя почти не считаются
// (иначе их материал натекал бы на кромку слоя)
void node_mats(vec2 wxz, out ivec4 m, out vec4 w, out float bl) {
	vec2 p = wxz / step_len - vec2(origin);
	ivec2 g0 = ivec2(floor(p));
	float acc[16];
	for (int i = 0; i < 16; i++) {
		acc[i] = 0.0;
	}
	float bsum = 0.0;
	float tsum = 0.0;
	for (int oy = -KR + 1; oy <= KR; oy++) {
		for (int ox = -KR + 1; ox <= KR; ox++) {
			ivec2 g = g0 + ivec2(ox, oy);
			if (g.x < 0 || g.y < 0 || g.x >= dims.x || g.y >= dims.y) {
				continue;
			}
			vec4 t = texelFetch(tmap, g, 0) * 255.0 + 0.5;
			int mats = int(t.g);
			int nib = int(t.b);
			int top = mats & 15;
			int und = (mats >> 4) & 15;
			float tr = float(nib & 15) / 15.0;
			float bn = float((nib >> 4) & 15) / 15.0;
			float reach = 1.0 + min(bn * blend_max / step_len, float(KR) - 1.0);
			float d = length(p - vec2(g));
			float tw = max(1.0 - d / reach, 0.0);
			if (t.a < 128.0) {
				tw *= 0.0001;
			}
			acc[top] += tw * (1.0 - tr);
			acc[und] += tw * tr;
			bsum += tw * bn;
			tsum += tw;
		}
	}
	float tot = 0.0;
	m = ivec4(0);
	w = vec4(0.0);
	for (int s = 0; s < 4; s++) {
		float best = -1.0;
		int bi = 0;
		for (int i = 0; i < 16; i++) {
			if (acc[i] > best) {
				best = acc[i];
				bi = i;
			}
		}
		m[s] = bi;
		w[s] = max(best, 0.0);
		tot += w[s];
		acc[bi] = -1.0;
	}
	w = tot > 0.000001 ? w / tot : vec4(1.0, 0.0, 0.0, 0.0);
	bl = tsum > 0.000001 ? bsum / tsum : 0.0;
}

// Граница рвётся шумом (только там, где вес между 0 и 1) и заостряется: вместо клетчатого градиента неровный край. Чем шире
// переход bl, тем меньше заострение (при 1 полностью плавный). Шум зависит от материала, а не от места узла среди окна,
// поэтому край непрерывен на границах ячеек
vec4 sharpen(vec4 w, ivec4 m, vec2 wxz, float bl) {
	float lo = 0.3 * (1.0 - bl);
	float hi = 1.0 - lo;
	vec4 r = w;
	for (int c = 0; c < 4; c++) {
		float fm = float(m[c]);
		float n = vnoise(wxz * edge_scale + vec2(fm * 13.1, fm * 7.7));
		float v = w[c];
		v = clamp(v + edge_noise * n * 4.0 * v * (1.0 - v), 0.0, 1.0);
		r[c] = smoothstep(lo, hi, v);
	}
	float s = r.x + r.y + r.z + r.w;
	if (s < 0.0001) {
		return w;
	}
	return r / s;
}

// Выборка слоя c массива текстур с заданными производными: ветвления по данным ниже безопасны (неявные производные в них не определены)
vec3 tex_g(int c, vec2 uv, vec2 gx, vec2 gy) {
	return textureGrad(texs, vec3(uv, float(c)), gx, gy).rgb * tints[c].rgb;
}

// Цвет материала слота c в точке: сверху проекция по XZ, на крутом склоне боковые проекции XY и ZY (их веса wx, wz, вес верха wy).
// На плоском (wy = 1) боковые не считаются: результат тот же, выборок вдвое-втрое меньше. dpx, dpy: производные позиции по экрану
vec3 mat_color(int c, vec3 p, float wy, float wx, float wz, vec3 dpx, vec3 dpy) {
	float tl = max(tiles[c], 0.1);
	vec3 top = tex_g(c, p.xz / tl, dpx.xz / tl, dpy.xz / tl);
	if (wy >= 0.9999) {
		return top;
	}
	vec3 side = (tex_g(c, p.zy / tl, dpx.zy / tl, dpy.zy / tl) * wx + tex_g(c, p.xy / tl, dpx.xy / tl, dpy.xy / tl) * wz) / max(wx + wz, 0.0001);
	return mix(side, top, wy);
}

void fragment() {
	// Производные для textureGrad считаются до отсечения и ветвлений по данным: в ветвях неявные производные не определены
	vec3 dpx = dFdx(v_pos);
	vec3 dpy = dFdy(v_pos);
	// Точки без слоя отсекаются первыми: голый стол почти бесплатен, цена растёт с площадью покрашенного
	if (v_th < thin_eps) {
		discard;
	}
	vec3 n = normalize(v_nrm);
	ivec4 m;
	vec4 w;
	float bl;
	node_mats(v_pos.xz, m, w, bl);
	// один материал (веса отсортированы по убыванию): граница не рвётся, шум не нужен
	if (w.x < 0.999) {
		w = sharpen(w, m, v_pos.xz, bl);
	}
	float wy = smoothstep(0.6, 0.9, abs(n.y));
	float wx = abs(n.x);
	float wz = abs(n.z);
	vec3 col = vec3(0.0);
	float ws = 0.0;
	for (int c = 0; c < 4; c++) {
		// материалы с ничтожным весом не выбираются (вклад меньше 0,2 %)
		if (w[c] > 0.002) {
			col += w[c] * mat_color(m[c], v_pos, wy, wx, wz, dpx, dpy);
			ws += w[c];
		}
	}
	col /= max(ws, 0.0001);
	// крутой склон уходит в материал склонов
	if (v_slope > 0.002) {
		col = mix(col, mat_color(slot_cliff, v_pos, wy, wx, wz, dpx, dpy), v_slope);
	}
	// крупная вариация яркости прячет повтор текстуры
	col *= 0.92 + 0.08 * vnoise(v_pos.xz * 0.12);
	ALBEDO = col;
	//ALBEDO = vec3(w.x);
	ROUGHNESS = 0.95;
}
