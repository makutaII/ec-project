// XX claude-library (новый файл)
// Штамп кисти по 3D-позиции (ATTN_22 §22.7.2.1, шаги C2.1, C2.2 и C2.3). Рисуется в SubViewport размером с слой краски.
// Для каждого текселя берётся его позиция на модели (карта позиций, UV2) и сравнивается с центрами штампов;
// форма штампа (круг, прямоугольник, текстурный конец, сухая кисть) считается в stamp_common.gdshaderinc.
// Образец (C2.3): вместо плоского цвета берётся цвет и пятнистость текстуры образца по позиции текселя на модели
// (triplanar: три проекции по осям, смесь по нормали), поэтому рисунок не рвётся на швах UV2.
// Накопление: render_target_clear_mode = ONCE и blend_mix, кадр дорисовывается поверх прежнего (проверено прототипом C2.0).
// Слой хранится в 16 битах (SubViewport.use_hdr_2d): при 8 битах краска при малом потоке «залипала» и темнела на мягком крае.
shader_type canvas_item;
render_mode blend_mix;

#include "res://core/library/paint/stamp_common.gdshaderinc"

uniform vec4 brush_color = vec4(1.0, 0.0, 0.0, 1.0);
uniform bool sample_on = false;
uniform sampler2D sample_tex : filter_linear, repeat_enable, hint_default_white;
uniform float sample_scale = 1.0;       // повторов текстуры на единицу длины опорного меша

// Образец по позиции: проекции на плоскости YZ, XZ и XY (v вдоль вертикали модели на боковых гранях), вес по нормали
vec4 sample_triplanar(vec3 p, vec3 n) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= max(w.x + w.y + w.z, 0.00001);
	vec4 cx = textureLod(sample_tex, p.zy * sample_scale, 0.0);
	vec4 cy = textureLod(sample_tex, p.xz * sample_scale + vec2(0.37, 0.11), 0.0);
	vec4 cz = textureLod(sample_tex, p.xy * sample_scale + vec2(0.71, 0.53), 0.0);
	return cx * w.x + cy * w.y + cz * w.z;
}

void fragment() {
	vec4 p = texture(pos_tex, UV);
	if (p.a < 0.5) {
		discard;
	}
	vec3 n = normalize(texture(nrm_tex, UV).xyz);
	float a = stamp_coverage(p.xyz, n);
	vec3 col = brush_color.rgb;
	if (sample_on) {
		vec4 s = sample_triplanar(p.xyz, n);
		col = s.rgb;
		a *= s.a;
	}
	COLOR = vec4(col, a);
}
