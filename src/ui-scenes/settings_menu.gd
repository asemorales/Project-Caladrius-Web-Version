extends MarginContainer

var _audio_stream_player: AudioStreamPlayer
var _is_mic_on: bool = false
var _settings_ver: String = "1.0.0"

@onready var volume_slider: HSlider = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/VolumeSlider
@onready var text_to_speech_option: OptionButton = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/TextToSpeechOption
@onready var speech_to_text_option: OptionButton = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/SpeechToTextOption
@onready var microphone_option: OptionButton = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/VBoxContainer/MicrophoneOption
@onready var microphone_button: Button = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/VBoxContainer/Button
@onready var main_menu: Control = get_node(".").get_parent()


func _ready() -> void:
	# Mute the bus used to test the mic
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Record"), true)

	# Setup the player for mic testing
	_audio_stream_player = AudioStreamPlayer.new()
	_audio_stream_player.stream = AudioStreamMicrophone.new()
	_audio_stream_player.autoplay = true
	_audio_stream_player.bus = "Record"
	add_child(_audio_stream_player)

	# Check if cookies will persist
	if not OS.is_userfs_persistent():
		print("WARNING: Cookies are not persistent!")

	# Update UI to display detected mics and select the default mic
	update_microphones()
	select_default_mic()

	# Create the settings cookie with default choices if no settings cookie is found
	var file_access
	if not _is_settings_valid():
		print("No saved settings detected! Making a default one...")
		var settings_data = {
			"volume": 100.0,
			"tts": 1,
			"stt": 1,
			"mic": "default",
			"version": _settings_ver
		}
		file_access = FileAccess.open_encrypted_with_pass("user://settings", FileAccess.WRITE, Globals.master_password)
		file_access.store_line(JSON.stringify(settings_data))
		file_access.close()
	
	var data = _load_settings()
	
	# Set the global vars
	Globals.volume = data["volume"]
	Globals.tts = data["tts"]
	Globals.stt = data["stt"]

	# Update UI to match loaded settings values
	volume_slider.value = Globals.volume
	text_to_speech_option.select(Globals.tts)
	speech_to_text_option.select(Globals.stt)


func _is_settings_valid() -> bool:
	if not FileAccess.file_exists("user://settings"):
		return false
	
	var data = _load_settings()
	
	if not data["version"] == _settings_ver:
		return false
	return true


func _load_settings() -> Variant:
	# Get the settings data
	var json: JSON = JSON.new()
	var file_access = FileAccess.open_encrypted_with_pass("user://settings", FileAccess.READ, Globals.master_password)
	var json_string: String = file_access.get_line()
	file_access.close()

	# Parse the settings data
	var json_parse_result: int = json.parse(json_string)
	if not json_parse_result == OK:
		printerr("settings can't be parsed as a json object")
		return { }
	return json.data


func _save_settings() -> void:
	var settings_data = {
		"volume": Globals.volume,
		"tts": Globals.tts,
		"stt": Globals.stt,
		"mic": "default",
		"version": _settings_ver
	}
	var file_access = FileAccess.open_encrypted_with_pass("user://settings", FileAccess.WRITE, Globals.master_password)
	file_access.store_line(JSON.stringify(settings_data))
	file_access.close()


func update_microphones() -> void:
	microphone_option.clear()
	var devices := AudioServer.get_input_device_list()
	var input_devices = 0
	for device in devices:
		var device_name = device
		microphone_option.add_item(device)
		microphone_option.set_item_metadata(input_devices, device_name)
		input_devices += 1
	

func select_default_mic() -> void:
	for i in range(microphone_option.item_count):
		if microphone_option.get_item_text(i) == "Default":
			microphone_option.select(i)
			AudioServer.input_device = microphone_option.get_item_metadata(i)


func _on_microphone_option_pressed() -> void:
	update_microphones()


func _on_volume_slider_drag_ended(value_changed: bool) -> void:
	if not value_changed:
		return
	
	Globals.volume = volume_slider.value


func _on_text_to_speech_option_selected(index: int) -> void:
	Globals.tts = index


func _on_speech_to_text_option_selected(index: int) -> void:
	Globals.stt = index


func _on_save_and_exit_button_pressed() -> void:
	_save_settings()

	main_menu.open_start_menu()


func _on_test_microphone_button_pressed() -> void:
	if _is_mic_on:
		AudioServer.set_bus_mute(AudioServer.get_bus_index("Record"), true)
		_is_mic_on = false
		microphone_button.text = "Test Mic (Off)"
	else:
		AudioServer.set_bus_mute(AudioServer.get_bus_index("Record"), false)
		_is_mic_on = true
		microphone_button.text = "Test Mic (On)"
