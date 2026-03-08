extends Control

var _on_secrets_loaded_callback = null

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

#This is just for testing. Delete in Future
# Nah, I need this (unless there's another button we can use to load the secrets)
func _on_start_button_pressed() -> void:
	if (OS.get_name() == "Web"):
		_on_secrets_loaded_callback = JavaScriptBridge.create_callback(_on_secrets_loaded)

		# Retrieve the 'gd_callbacks' object
		var gdcallbacks: JavaScriptObject = JavaScriptBridge.get_interface("gd_callbacks")

		# Assign the callbacks
		gdcallbacks.dataLoaded = _on_secrets_loaded_callback

		# Load secrets
		JavaScriptBridge.eval("loadData()")

		print("Loaded secrets via web!")

		await Globals.secrets_loaded
	else:
		if FileAccess.file_exists("res://src/auth/secrets.json"):
			# Get the data
			var json: JSON = JSON.new()
			var file_access = FileAccess.open("res://src/auth/secrets.json", FileAccess.READ)
			var json_string: String = file_access.get_line()
			file_access.close()

			# Parse the data
			var json_parse_result: int = json.parse(json_string)
			if not json_parse_result == OK:
				printerr("secrets can't be parsed as a json object")
				visible = false
				return
			
			# Save them in Globals
			var dup = json.data.duplicate(true)
			Globals.api_keys = dup["api_keys"]
			Globals.key_file = dup["key_file"]
			Globals.key_file2 = dup["key_file2"]

			Globals.secrets_loaded.emit()
	
	visible = false


func _on_secrets_loaded(data: Array):
	if data.size() == 0:
		return
	
	var json: JSON = JSON.new()
	var json_parse_result: int = json.parse(data[0])
	if not json_parse_result == OK:
		printerr("secrets (web) can't be parsed as a json object")
		return
	
	var dup = json.data.duplicate(true)
	Globals.api_keys = dup["api_keys"]
	Globals.key_file = dup["key_file"]
	Globals.key_file2 = dup["key_file2"]
	Globals.secrets_loaded.emit()
