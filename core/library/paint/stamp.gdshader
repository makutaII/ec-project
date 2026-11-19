// XX claude-library (новый файл)
// Штамп кисти по 3D-позиции (ATTN_22 §22.7.2.1, шаги C2.1, C2.2 и C2.3). Рисуется в SubViewport размером с слой краски.
// Для каждого текселя берётся его позиция на модели (карта позиций, UV2) и сравнивается с центрами штампов;
// форма штампа (круг, прямоугольник, текстурный конец, сухая кисть) считается в stamp_common.gdshaderinc.
// Образец (C2.3): вместо плоского цвета берётся цвет и пятнистость текстуры образца по позиции текселя на модели
// (triplanar: три проекции по осям, смесь по нормали), поэтому рисунок не рвётся на швах UV2.
// Рельеф (C2.2a): сухая кисть и смывка красят только там, где карта рельефа (relief_bake.gdshader) даёт контраст яркости
// текстуры нужного знака; на ровной поверхности не красят совсем.
// Накопление: render_target_clear_mode = ONCE и blend_mix, кадр дорисовывается поверх прежнего (проверено прототипом C2.0).
// Слой хранится в 16 битах (SubViewport.use_hdr_2d): при 8 битах краска при малом потоке «залипала» и темнела на мягком крае.
shader_type canvas_item;
render_mode blend_mix;

#include "res://core/library/paint/stamp_common.gdshaderinc"

uniform vec4 brush_color = vec4(1.0, 0.0, 0.0, 1.0);
uniform bool sample_on = false;
uniform sampler2D sample_tex : filter_linear, repeat_enable, hint_default_white;
uniform float sample_scale = 1.0;       // повторов текстуры на единицу длины опорного меша
uniform vec2 sample_shift = vec2(0.0);  // сдвиг образца в тайлах: у каждого мазка свой, поэтому рисунок не повторяется
uniform bool decal_on = false;          // декаль: картинка со своим цветом вместо круглого штампа
uniform sampler2D decal_tex : filter_linear_mipmap, repeat_disable, hint_default_white;
uniform vec2 decal_box = vec2(1.0, 1.0);   // полуразмеры картинки в долях радиуса (большая сторона 1)
uniform bool decal_mirror = false;
uniform bool decal_tint = true;         // умножить цвет картинки на цвет палитры (белые формы)
uniform float decal_lod = 0.0;          // уровень мипмапа: по размеру декали в текселях слоя (считает движок)
uniform bool relief_on = false;         // сухая кисть и смывка: красить только по рельефу
uniform sampler2D relief_tex : filter_nearest, repeat_disable;   // R: 0.5 + контраст яркости, G: тексель покрыт
uniform float relief_dir = 1.0;         // 1 выступы и светлые кромки, -1 впадины и тёмные тени
uniform float relief_sens = 1.0;        // чувствительность: во сколько раз усиливается контраст

// Вес рельефа в текселе: 0 на ровном, до 1 на кромке нужной стороны. Тексель за краем острова берёт ближайший покрытый
float relief_weight(vec2 uv) {
	vec4 r = texture(relief_tex, uv);
	if (r.g < 0.5) {
		vec2 px = 1.0 / vec2(textureSize(relief_tex, 0));
		for (int k = 0; k < 8; k++) {
			float a = float(k) * 0.785398;
			vec4 q = texture(relief_tex, uv + vec2(cos(a), sin(a)) * px * 1.5);
			if (q.g > 0.5) {
				r = q;
				break;
			}
		}
		if (r.g < 0.5) {
			return 0.0;
		}
	}
	float m = relief_dir * (r.r - 0.5) * 2.0 * relief_sens;
	return smoothstep(0.04, 0.16, m);
}

// Образец по позиции: проекции на плоскости YZ, XZ и XY (v вдоль вертикали модели на боковых гранях), вес по нормали
vec4 sample_triplanar(vec3 p, vec3 n) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= max(w.x + w.y + w.z, 0.00001);
	vec4 cx = textureLod(sample_tex, p.zy * sample_scale + sample_shift, 0.0);
	vec4 cy = textureLod(sample_tex, p.xz * sample_scale + vec2(0.37, 0.11) + sample_shift, 0.0);
	vec4 cz = textureLod(sample_tex, p.xy * sample_scale + vec2(0.71, 0.53) + sample_shift, 0.0);
	return cx * w.x + cy * w.y + cz * w.z;
}

// Декаль первого штампа пачки: картинка лежит в касательной плоскости, вправо вдоль stamp_tan, вверх вдоль нормаль x вправо
vec4 decal_color(vec3 p, vec3 n) {
	float r = max(stamps[0].w, 0.00001);
	vec3 q = p - stamps[0].xyz;
	vec3 sn = normalize(stamp_nrm[0].xyz);
	vec3 t = stamp_tan[0].xyz;
	vec3 b = cross(sn, t);
	vec2 uv = vec2(dot(q, t), dot(q, b)) / r / max(decal_box, vec2(0.0001));
	if (decal_mirror) {
		uv.x = -uv.x;
	}
	vec2 tuv = vec2(uv.x * 0.5 + 0.5, 0.5 - uv.y * 0.5);
	bool inside = tuv.x >= 0.0 && tuv.x <= 1.0 && tuv.y >= 0.0 && tuv.y <= 1.0;
	vec4 c = textureLod(decal_tex, clamp(tuv, vec2(0.0), vec2(1.0)), decal_lod);
	float slab = abs(dot(q, sn)) <= r ? 1.0 : 0.0;
	float facing = smoothstep(0.05, 0.35, dot(n, sn));
	return vec4(c.rgb, inside ? c.a * slab * facing * flow : 0.0);
}

void fragment() {
	vec4 p = texture(pos_tex, UV);
	if (p.a < 0.5) {
		discard;
	}
	vec3 n = normalize(texture(nrm_tex, UV).xyz);
	// return в fragment() Godot не допускает, поэтому ветки if / else
	if (decal_on) {
		vec4 d = decal_color(p.xyz, n);
		vec3 dc = decal_tint ? d.rgb * brush_color.rgb : d.rgb;
		COLOR = vec4(dc, d.a);
	} else {
		float a = stamp_coverage(p.xyz, n);
		if (relief_on) {
			a *= relief_weight(UV);
		}
		vec3 col = brush_color.rgb;
		if (sample_on) {
			vec4 s = sample_triplanar(p.xyz, n);
			col = s.rgb;
			a *= s.a;
		}
		COLOR = vec4(col, a);
	}
}
