// XX claude-library (новый файл)
// Накладка краски поверх материала модели (ATTN_22 §22.7.2.1, шаг C2.1): читает слой краски по UV2.
// Слой хранит цвет, умноженный на альфу (так складывается blend_mix в пустой буфер), и значения sRGB, потому что
// 2D рисует в sRGB: для ALBEDO их надо разделить на альфу и перевести в линейные. Прототип C2.0 это подтверждает:
// next_pass не мерцает, сдвиг по нормали не нужен.
shader_type spatial;
render_mode blend_mix, cull_back;

uniform sampler2D layer : filter_linear_mipmap, repeat_disable;
uniform bool premultiplied = true;
uniform bool srgb_decode = true;
uniform float rough : hint_range(0.0, 1.0) = 0.6;
uniform float metal : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D mask_tex : filter_linear, repeat_disable, hint_default_transparent;   // маска Library: A закрыта
uniform bool mask_show = false;

void fragment() {
	vec4 c = texture(layer, UV2);
	vec3 col = c.rgb;
	if (premultiplied) {
		col = c.a > 0.0001 ? c.rgb / c.a : vec3(0.0);
	}
	if (srgb_decode) {
		col = pow(max(col, vec3(0.0)), vec3(2.2));
	}
	float a = c.a;
	if (mask_show) {
		// закрытые маской участки красноватым: краска туда не ложится
		float m = texture(mask_tex, UV2).a;
		col = mix(col, vec3(1.0, 0.1, 0.1), clamp(m * 0.9, 0.0, 1.0) * (1.0 - c.a * 0.5));
		a = max(c.a, m * 0.45);
	}
	ALBEDO = col;
	ALPHA = a;
	ROUGHNESS = rough;
	METALLIC = metal;
}
