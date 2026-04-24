extends Node

@onready var loading_screen := $LoadingScreenLayer/LoadingScreen
@onready var main_menu := $MainMenuLayer/MainMenu
@onready var patient_interview: Node2D = $PatientInterview

func _ready() -> void:
	JavaScriptBridge.eval("setupAudio();")

	main_menu.visible = true