extends Node2D

class_name PatientModel

@onready var anim: AnimationPlayer = $AnimationPlayer


func play_idle() -> void:
	anim.play("idle")


func play_thinking() -> void:
	anim.play("thinking")
