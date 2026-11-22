// XX claude-library (новый файл)
// Общая часть штампа кисти и ластика (ATTN_22 §22.7.2.1, шаг C2.2): uniform-ы и покрытие текселя штампами.
// Подключается через #include в stamp.gdshader и stamp_erase.gdshader (в самом файле нет shader_type и render_mode).
// Штамп задан центром и радиусом (stamps), нормалью в точке попадания (stamp_nrm), направлением конца в касательной
// плоскости и запасом краски (stamp_tan: xyz направление, w запас 0..1).

uniform sampler2D pos_tex : filter_nearest, repeat_disable;   // xyz: позиция, a: 1 если тексель покрыт
uniform sampler2D nrm_tex : filter_nearest, repeat_disable;   // xyz: нормаль
uniform sampler2D tip_tex : filter_linear, repeat_disable, hint_default_white;   // R: плотность конца кисти
uniform vec4 stamps[32];       // xyz: центр штампа (локальные координаты опорного меша), w: радиус
uniform vec4 stamp_nrm[32];    // xyz: нормаль в точке попадания
uniform vec4 stamp_tan[32];    // xyz: направление конца в касательной плоскости, w: запас краски
uniform int stamp_count = 0;
uniform bool mask_on = false;                                       // есть маска: краска не ложится там, где маска закрыта
uniform sampler2D mask_tex : filter_nearest, repeat_disable, hint_default_transparent;   // A: насколько тексель закрыт

uniform float flow : hint_range(0.0, 1.0) = 1.0;
uniform float hardness : hint_range(0.0, 0.99) = 0.5;
uniform bool tip_plain = true;             // обычный круглый штамп без текстуры и без tip_box (быстрый путь)
uniform int tip_shape = 0;                 // 0 круг (эллипс по tip_box), 1 прямоугольник
uniform vec2 tip_box = vec2(1.0, 1.0);     // полуразмеры конца вдоль направления штриха и поперёк, доли радиуса
uniform bool tip_textured = false;         // умножать на текстуру tip_tex
uniform float dry : hint_range(0.0, 1.0) = 0.0;   // сухая кисть: порог по текстуре растёт, пока запас краски убывает

// Множитель маски: 1 открыто, 0 закрыто (маска это скотч и трафарет, ATTN_22 шаг C2.5)
float mask_open(vec2 uv) {
	return mask_on ? 1.0 - texture(mask_tex, uv).a : 1.0;
}

// Покрытие текселя всеми штампами пачки (штампы накладываются как «поверх»: a + c * (1 - a))
float stamp_coverage(vec3 p, vec3 n) {
	float a = 0.0;
	for (int i = 0; i < 32; i++) {
		if (i >= stamp_count) {
			break;
		}
		float r = max(stamps[i].w, 0.00001);
		vec3 q = p - stamps[i].xyz;
		vec3 sn = normalize(stamp_nrm[i].xyz);
		float c;
		if (tip_plain) {
			// обычный круглый штамп: расстояние в пространстве (огибает кривую поверхность)
			c = 1.0 - smoothstep(hardness, 1.0, length(q) / r);
		} else {
			vec3 t = stamp_tan[i].xyz;
			vec3 b = cross(sn, t);
			vec2 uv = vec2(dot(q, t), dot(q, b)) / r;
			vec2 e = abs(uv) / max(tip_box, vec2(0.0001));
			float m = tip_shape == 1 ? max(e.x, e.y) : length(e);
			c = 1.0 - smoothstep(hardness, 1.0, m);
			// слой за тонкой деталью (далеко по нормали) не красить
			if (abs(dot(q, sn)) > r) {
				c = 0.0;
			}
			if (tip_textured && c > 0.0) {
				vec2 tuv = uv / max(tip_box, vec2(0.0001)) * 0.5 + 0.5;
				if (tuv.x < 0.0 || tuv.x > 1.0 || tuv.y < 0.0 || tuv.y > 1.0) {
					c = 0.0;
				} else {
					float tv = textureLod(tip_tex, tuv, 0.0).r;
					if (dry > 0.0) {
						float thr = (1.0 - clamp(stamp_tan[i].w, 0.0, 1.0)) * dry;
						c *= smoothstep(thr, thr + 0.15, tv);
					} else {
						c *= tv;
					}
				}
			}
		}
		// не красить обратную сторону тонких деталей
		float facing = smoothstep(0.05, 0.35, dot(n, sn));
		c *= facing * flow;
		a = a + c * (1.0 - a);
	}
	return a;
}
