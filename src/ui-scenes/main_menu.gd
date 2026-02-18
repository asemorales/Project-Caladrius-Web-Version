extends Control

@onready var start_menu: MarginContainer = $StartMenu
@onready var settings_menu: MarginContainer = $SettingsMenu


func _ready() -> void:
	open_start_menu()


func open_start_menu() -> void:
	settings_menu.visible = false
	start_menu.visible = true


func open_settings_menu() -> void:
	start_menu.visible = false
	settings_menu.visible = true


func _on_settings_button_pressed() -> void:
	open_settings_menu()


func _on_exit_only_button_pressed() -> void:
	open_start_menu()
