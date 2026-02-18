shader_type canvas_item;

//Hat
uniform vec4 hat_color : source_color;
uniform vec4 hat_replace_color : source_color;
uniform float hat_color_threshold : hint_range(0.0, 1.0, 0.001);

//Hair
uniform vec4 hair_color : source_color;
uniform vec4 hair_replace_color : source_color;
uniform float hair_color_threshold : hint_range(0.0, 1.0, 0.001);

//Skin
uniform vec4 skin_color : source_color;
uniform vec4 skin_replace_color : source_color;
uniform float skin_color_threshold : hint_range(0.0, 1.0, 0.001);

//Clothes
uniform vec4 clothes_color : source_color;
uniform vec4 clothes_replace_color : source_color;
uniform float clothes_color_threshold : hint_range(0.0, 1.0, 0.001);

void fragment() {
	// Called for every pixel the material is visible on.
	vec4 tex_color = texture(TEXTURE, UV);

	float hat_distance = length(tex_color.rgb - hat_color.rgb);
	float hair_distance = length(tex_color.rgb - hair_color.rgb);
	float skin_distance = length(tex_color.rgb - skin_color.rgb);
	float clothes_distance = length(tex_color.rgb - clothes_color.rgb);

	if(hat_distance < hat_color_threshold){
		tex_color = hat_replace_color;
	}else if(hair_distance < hair_color_threshold){
		tex_color = hair_replace_color;
	}else if(skin_distance < skin_color_threshold){
		tex_color = skin_replace_color;
	}else if(clothes_distance < clothes_color_threshold){
		tex_color = clothes_replace_color;
	}

	COLOR = tex_color;
}