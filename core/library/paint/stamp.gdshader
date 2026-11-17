// XX claude-library (новый файл)
// Штамп кисти по 3D-позиции (ATTN_22 §22.7.2.1, шаги C2.1 и C2.2). Рисуется в SubViewport размером с слой краски.
// Для каждого текселя берётся его позиция на модели (карта позиций, UV2) и сравнивается с центрами штампов;
// форма штампа (круг, прямоугольник, текстурный конец, сухая кисть) считается в stamp_common.gdshaderinc.
// Накопление: render_target_clear_mode = ONCE и blend_mix, кадр дорисовывается поверх прежнего (проверено прототипом C2.0).
// Слой хранится в 16 битах (SubViewport.use_hdr_2d): при 8 битах краска при малом потоке «залипала» и темнела на мягком крае.
shader_type canvas_item;
render_mode blend_mix;

#include "res://core/library/paint/stamp_common.gdshaderinc"

uniform vec4 brush_color = vec4(1.0, 0.0, 0.0, 1.0);

void fragment() {
	vec4 p = texture(pos_tex, UV);
	if (p.a < 0.5) {
		discard;
	}
	vec3 n = normalize(texture(nrm_tex, UV).xyz);
	COLOR = vec4(brush_color.rgb, stamp_coverage(p.xyz, n));
}
