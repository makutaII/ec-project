shader_type spatial;

// Дорожное полотно с разметкой в материале (ATTN_28, CS1b): линия рисуется шейдером по UV меша, а не отдельной геометрией.
// UV меша (TrackMeshBuilder.sweep) при ballast_uv_tile = (1, 0): UV.x вдоль пути, в ю с минусом; UV.y поперёк, 0..1 от левого края до правого.
// Свою линию можно задать иначе: подставить в style.ballast_material обычный StandardMaterial3D с текстурой или это же
// материал с текстурой асфальта (use_asphalt_texture). Тайл вдоль пути берётся из style.ballast_uv_tile.x.

uniform vec4 asphalt_color : source_color = vec4(0.17, 0.17, 0.18, 1.0);
uniform float asphalt_roughness : hint_range(0.0, 1.0) = 0.95;
// Текстура асфальта вместо цвета: тайлы на ю вдоль и поперёк (по доле ширины 0..1 поперёк)
uniform bool use_asphalt_texture = false;
uniform sampler2D asphalt_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 asphalt_tiling = vec2(0.1, 4.0);

// Линия: цвет, положение поперёк (0 левый край, 0.5 центр, 1 правый), ширина в долях ширины полотна
uniform vec4 line_color : source_color = vec4(0.9, 0.9, 0.84, 1.0);
uniform float line_pos : hint_range(0.0, 1.0) = 0.5;
uniform float line_width : hint_range(0.0, 0.5) = 0.04;
// Длина штриха и пробела, ю. Любое из двух 0 = сплошная линия. Узор начинается с нуля на каждом куске дороги,
// поэтому на стыке он непрерывен, если длина куска кратна штриху плюс пробелу (у стартовых прямых 10 и 20 ю: 2.5 + 2.5)
uniform float dash_length = 2.5;
uniform float gap_length = 2.5;
// Включить линию. false: чистый асфальт
uniform bool line_enabled = true;

void fragment() {
	float along = -UV.x;
	float across = UV.y;
	vec3 base = asphalt_color.rgb;
	if (use_asphalt_texture) {
		base = texture(asphalt_texture, vec2(along, across) * asphalt_tiling).rgb;
	}
	float mask = 0.0;
	if (line_enabled) {
		float aw = max(fwidth(across), 0.0001);
		float d = abs(across - line_pos);
		float across_mask = 1.0 - smoothstep(line_width * 0.5 - aw, line_width * 0.5 + aw, d);
		float dash_mask = 1.0;
		if (dash_length > 0.0 && gap_length > 0.0) {
			float period = dash_length + gap_length;
			float m = mod(along, period);
			float ad = max(fwidth(along), 0.0001);
			dash_mask = smoothstep(0.0, ad, m) * smoothstep(0.0, ad, dash_length - m);
		}
		mask = across_mask * dash_mask;
	}
	ALBEDO = mix(base, line_color.rgb, mask);
	ROUGHNESS = asphalt_roughness;
}
