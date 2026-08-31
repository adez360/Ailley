shader_type canvas_item;

// 角色被滑鼠指到時的描邊。
//
// 影格是從 sprite sheet 切出來的 AtlasTexture，UV 走的是整張圖集的座標，
// 而相鄰影格之間沒有留白 —— 取樣鄰近像素時若不夾在本影格的範圍內，
// 描出來的會是隔壁影格的身體輪廓。region 就是拿來夾這個範圍的，
// 由 character.gd 在換影格時餵進來。

// 本影格在圖集裡的 UV 範圍：(min_x, min_y, max_x, max_y)
uniform vec4 region = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float thickness : hint_range(1.0, 4.0) = 1.0;

float alpha_at(sampler2D tex, vec2 uv) {
	if (uv.x < region.x || uv.y < region.y || uv.x > region.z || uv.y > region.w) {
		return 0.0;
	}
	return texture(tex, uv).a;
}

void fragment() {
	// COLOR 在這裡已經是套用過 modulate／self_modulate 的貼圖顏色（Godot
	// canvas_item shader 進入 fragment() 前的預設值），不能像 alpha_at() 的
	// 鄰近像素取樣那樣直接對 TEXTURE 重新取樣——那樣會繞過 sprite.modulate，
	// 死亡角色的灰色 tint（_apply_death_tint()）在描邊生效期間就會消失
	// （issue #828）
	vec4 base = COLOR;
	vec2 span = TEXTURE_PIXEL_SIZE * thickness;

	float around = max(
		max(alpha_at(TEXTURE, UV + vec2(span.x, 0.0)), alpha_at(TEXTURE, UV - vec2(span.x, 0.0))),
		max(alpha_at(TEXTURE, UV + vec2(0.0, span.y)), alpha_at(TEXTURE, UV - vec2(0.0, span.y)))
	);

	// 只畫在「自己是透明、隔壁有東西」的像素上，角色本身不會被蓋掉
	float edge = around * (1.0 - base.a);
	COLOR = mix(base, outline_color, edge);
}
