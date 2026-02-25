extends Node

@onready var loading_screen := $LoadingScreenLayer/LoadingScreen
@onready var main_menu := $MainMenuLayer/MainMenu


func _ready() -> void:
	loading_screen.start_loading_screen()
	await get_tree().create_timer(5).timeout
	main_menu.visible = true
	loading_screen.stop_loading_screen()
