extends Control

@onready var anim := $AnimationPlayer

func start_loading_screen() -> void:
	anim.play("Fade_In")
	await anim.animation_finished
	anim.play("Loading")


func stop_loading_screen() -> void:
	anim.play("Fade_Out")
