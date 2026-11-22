// XX claude-library (новый файл)
// Ластик: тот же штамп (stamp_common.gdshaderinc), но слой умножается на (1 - покрытие). blend_mul умножает и цвет, и
// альфу слоя; слой хранит премультиплицированный цвет, поэтому умножение всех каналов на одно число стирает правильно.
shader_type canvas_item;
render_mode blend_mul;

#include "res://core/library/paint/stamp_common.gdshaderinc"

uniform vec4 brush_color = vec4(1.0);   // не используется, нужен для общего кода движка

void fragment() {
	vec4 p = texture(pos_tex, UV);
	if (p.a < 0.5) {
		discard;
	}
	vec3 n = normalize(texture(nrm_tex, UV).xyz);
	float k = 1.0 - stamp_coverage(p.xyz, n) * mask_open(UV);
	COLOR = vec4(k, k, k, k);
}
