extends Node2D

@onready var enter_here: TextEdit = $CanvasLayer/HBoxContainer/CenterContainer/MarginContainer/EnterHere
@onready var transcript: RichTextLabel = $CanvasLayer/CenterContainer2/VBoxContainer/MarginContainer/Transcript
@onready var mentor_comment: RichTextLabel = $CanvasLayer/CenterContainer2/VBoxContainer/MarginContainer2/MarginContainer/VBoxContainer/MentorComment



func _on_enter_button_pressed() -> void:
	if enter_here.text != "":
		transcript.append_text("Doctor: " + enter_here.text + "\n")
		enter_here.text = ""
