extends Node2D

class_name Patient

@onready var anim: AnimationPlayer = $AnimationPlayer


func play_idle() -> void:
	anim.play("idle")


func play_thinking() -> void:
	anim.play("thinking")
