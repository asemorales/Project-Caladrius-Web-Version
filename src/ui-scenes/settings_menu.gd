extends MarginContainer

@onready var volume_slider: HSlider = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/VolumeSlider
@onready var text_to_speech_option: OptionButton = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/TextToSpeechOption
@onready var speech_to_text_option: OptionButton = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/SpeechToTextOption
@onready var microphone_option: OptionButton = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/VBoxContainer/MicrophoneOption


func _ready() -> void:
	update_microphones()
	select_default_mic()


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
