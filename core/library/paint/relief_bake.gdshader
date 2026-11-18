// XX claude-library (новый файл)
// Запекание рельефа для сухой кисти и смывки (ATTN_22 §22.7.2.1, шаг C2.2a). Рисуется в SubViewport размером с слой краски:
// треугольники меша кладутся в пространство UV2 слоя (вершины = UV2 * размер слоя), а UV1 меша выбирает цвет базовой текстуры.
// Рельеф это контраст яркости текстуры с её окружением: яркость в точке минус средняя яркость кольца вокруг (радиус width
// в пикселях слоя). Больше нуля: светлее окружения (выступ, светлая кромка), меньше нуля: темнее (впадина, тёмная тень),
// ноль на ровной поверхности. Выемки, нарисованные в текстуре, так тоже видны. Без текстуры у материала рельеф нулевой.
// R: 0.5 + контраст (контраст от -0.5 до 0.5), G: 1 там, где тексель покрыт меш-ом (иначе 0).
shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D albedo_tex : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform bool has_tex = false;
uniform vec2 uv_scale = vec2(1.0, 1.0);
uniform vec2 uv_offset = vec2(0.0, 0.0);
uniform float width = 3.0;

float lum(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

void fragment() {
	float rel = 0.0;
	if (has_tex) {
		vec2 uv = UV * uv_scale + uv_offset;
		vec2 dx = dFdx(uv);      // сдвиг UV1 на один тексель слоя вдоль x и y
		vec2 dy = dFdy(uv);
		float l0 = lum(texture(albedo_tex, uv).rgb);
		float ring = 0.0;
		for (int i = 0; i < 8; i++) {
			float a = float(i) * 0.785398;
			vec2 o = (cos(a) * dx + sin(a) * dy) * width;
			ring += lum(texture(albedo_tex, uv + o).rgb);
		}
		rel = l0 - ring / 8.0;
	}
	COLOR = vec4(clamp(rel, -0.5, 0.5) + 0.5, 1.0, 0.0, 1.0);
}
