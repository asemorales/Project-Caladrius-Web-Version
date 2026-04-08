extends Node2D

class_name PatientModel

@onready var anim: AnimationPlayer = $AnimationPlayer
@onready var face: AnimatedSprite2D = $Polygons/Face

var previously_blinked : bool = false
var thinking_left : bool = true
var talking : bool = false

func play_idle() -> void:
	anim.play("idle")


func play_thinking() -> void:
	anim.play("thinking")


#---------------------------------------
#          FACIAL ANIMATIONS
#---------------------------------------
func face_play_blink() -> void:
	if not talking:
		if not previously_blinked:
			face.play("blink")
		
		previously_blinked = not previously_blinked

func face_play_thinking() -> void:
	if thinking_left:
		face.play("thinking_left")
	else:
		face.play("thinking_right")

func face_play_think_transition() -> void:
	if thinking_left:
		face.play("think_transition_to_right")
	else:
		face.play("think_transition_to_left")
	
	thinking_left = not thinking_left


func face_play_talking() -> void:
	face.play("talking")
	talking = true

func face_play_default() -> void:
	face.play("default")
	talking = false

func _on_face_animation_finished() -> void:
	if face.animation == "blink" and not talking:
		face.play("default")
	
	if face.animation == "think_transition_to_right" or face.animation == "think_transition_to_left":
		face_play_thinking()
