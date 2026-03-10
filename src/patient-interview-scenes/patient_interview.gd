extends Node2D

@export var freq_penalty: float = 0
@export var max_tokens: int = 1024
@export var presence_penalty: float = 0
@export var stream: bool = false
@export var temp: float = 1

# STT
var _stt_http_request: HTTPRequest
var _stt_endpoint: String
var _stt_headers: PackedStringArray
var _stt_audio_stream_player : AudioStreamPlayer2D
var _stt_audio_effect: AudioEffect
var _mix_rate: float

# LLM
var _chat_http_request: HTTPRequest
var _chat_endpoint: String = "https://api.openai.com/v1/chat/completions"
var _chat_model: String = "ft:gpt-4o-mini-2024-07-18:ateneo-school-of-medicine-and-public-health:patient-eng-v11:Bb0jj7Oz"
var _chat_headers: PackedStringArray
var _messages = []

# TTS
var _tts_http_request: HTTPRequest
var _tts_endpoint: String
var _tts_headers: PackedStringArray
var _tts_audio_stream_player: AudioStreamPlayer2D

var _stored_streamed_audio: PackedByteArray

var _elevenlabs_voice_id_male: String = "IKne3meq5aSn9XLyUdCD"
var _elevenlabs_voice_id_female: String = "EXAVITQu4vr4xnSDxMaL"

@onready var enter_here: TextEdit = $CanvasLayer/HBoxContainer/CenterContainer/MarginContainer/EnterHere
@onready var transcript: RichTextLabel = $CanvasLayer/CenterContainer2/VBoxContainer/MarginContainer/Transcript
@onready var mentor_comment: RichTextLabel = $CanvasLayer/CenterContainer2/VBoxContainer/MarginContainer2/MarginContainer/VBoxContainer/MentorComment


func _ready() -> void:
	await Globals.secrets_loaded
	
	# STT
	_stt_http_request = HTTPRequest.new()
	add_child(_stt_http_request)
	_stt_http_request.timeout = 20
	_stt_http_request.request_completed.connect(_on_stt_request_completed)

	_stt_audio_stream_player = AudioStreamPlayer2D.new()
	_stt_audio_stream_player.stream = AudioStreamMicrophone.new()
	_stt_audio_stream_player.set_bus("Record")
	add_child(_stt_audio_stream_player)

	var idx = AudioServer.get_bus_index("Record")
	_stt_audio_effect = AudioServer.get_bus_effect(idx, 0)

	_mix_rate = AudioServer.get_mix_rate()
	_mix_rate = clamp(_mix_rate, 8000, 48000)

	# LLM
	_chat_http_request = HTTPRequest.new()
	add_child(_chat_http_request)
	_chat_http_request.timeout = 20
	_chat_http_request.request_completed.connect(_on_llm_request_completed)

	# TTS
	_tts_http_request = HTTPRequest.new()
	add_child(_tts_http_request)
	_tts_http_request.timeout = 20
	_tts_http_request.request_completed.connect(_on_tts_request_completed)

	_tts_audio_stream_player = AudioStreamPlayer2D.new()
	add_child(_tts_audio_stream_player)


	# Setup stt, llm, and tts modules
	_setup_modules()


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("Record"):
		# Debug
		print("Pressed Record")

		# Record mic
		_stt_audio_effect.set_recording_active(true)
	elif Input.is_action_just_released("Record"):
		# Debug
		print("Released Record")

		# Get recording and stop recording mic
		var recording = _stt_audio_effect.get_recording()
		_stt_audio_effect.set_recording_active(false)
		call_stt(recording.data)


func _setup_modules() -> void:
	_setup_stt()
	_setup_llm()
	_setup_tts()


func _setup_stt() -> void:
	match Globals.stt:
		0: # Google Cloud v1
			_stt_endpoint = "https://speech.googleapis.com/v1/speech:recognize?key=" + Globals.api_keys["GoogleCloud"]
			_stt_headers = PackedStringArray(["Content-Type: audio/wav", "accept: */*"])
		1: # Google Cloud v2
			match Globals.language:
				0:
					pass
				1:
					pass
				_:
					pass
			_stt_endpoint = ""
			
			_stt_headers = PackedStringArray([])
		2: # Local STT
			_stt_endpoint = ""
			_stt_headers = PackedStringArray([])
		_:
			printerr("Invalid STT option!")


func _setup_llm() -> void:
	_chat_headers = PackedStringArray(["Content-type: application/json", "Authorization: Bearer " + Globals.api_keys["ChatGPT"]])


func _setup_tts() -> void:
	match Globals.tts:
		0: # ElevenLabs
			_tts_endpoint = "https://api.elevenlabs.io/v1/text-to-speech/" + _elevenlabs_voice_id_female
			_tts_headers = PackedStringArray(["accept: audio/mpeg", "xi-api-key: " + Globals.api_keys["ElevenLabs"], "Content-Type: application/json"])
		1: # Google Cloud
			_tts_endpoint = "https://texttospeech.googleapis.com/v1/text:synthesize?key=" + Globals.api_keys["GoogleCloud"]
			_tts_headers = PackedStringArray(["accept: */*", "xi-api-key: " + Globals.api_keys["GoogleCloud"], "Content-Type: application/json"])
		2: # Godot TTS
			_tts_endpoint = ""
			_tts_headers = PackedStringArray([])
		_:
			printerr("Invalid TTS option!")


func _on_enter_button_pressed() -> void:
	if enter_here.text != "":
		transcript.append_text("Doctor: " + enter_here.text + "\n")

		call_llm(enter_here.text)

		enter_here.text = ""


## Send audio to STT module to get the text
func call_stt(audio) -> void:
	match Globals.stt:
		0:
			_call_GoogleCloud_v1_stt(audio)
		1:
			_call_GoogleCloud_v2_stt(audio)
		2:
			pass
		_:
			pass


func _call_GoogleCloud_v1_stt(audio) -> void:
	var body = JSON.stringify({
		"config": {
			"encoding": "LINEAR16",
			"sampleRateHertz": clamp(_mix_rate, 8000, 48000),
			"languageCode": "en-US",
			"alternativeLanguageCodes": [
				"fil-PH"
			]
		},
		"audio": {
			"content": Marshalls.raw_to_base64(audio)
		},
	})

	var error = _stt_http_request.request(_stt_endpoint, _stt_headers, HTTPClient.METHOD_POST, body)


func _call_GoogleCloud_v2_stt(audio: AudioStreamWAV) -> void:
	pass


## Sends text to the llm module to receive a response
func call_llm(text: String) -> void:
	_call_ChatGPT(text)


# Sends text to ChatGPT to receive a response
func _call_ChatGPT(text: String) -> void:
	# Prevent calling ChatGPT again if the previous call is unresolved
	# if _is_calling_chatgpt:
	# 	return
	# _is_calling_chatgpt = true

	# Also send text to the mentor AI for grading
	# _mentor_http_request.call_ChatGPT(text)

	#RAG
	# var keyword_len: int = _keywords.size()
	# var context_len: int = _context.size()

	# # Check for keywords of all patient info categories
	# for i in range(0, 219):
	# 	# OOB prevention
	# 	if i >= keyword_len or i >= context_len:
	# 		break
		
	# 	# Check if keyword was mentioned
	# 	for keyword in _keywords[i]:
	# 		if keyword in text:
	# 			# Add the appropriate context and stop checking keywords for the same context
	# 			_messages += [_context[i]]
	# 			break

	# Append the text to _messages for submission to ChatGPT and _convo for storage to a local transcript
	_messages.append({
		"role": "user",
		"content": text
	})
	# _convo.append({
	# 	"role": "User",
	# 	"content": text
	# })

	# Build the HTTP request body
	var body: String = JSON.stringify({
		"messages": _messages,
		"model": _chat_model,
		"frequency_penalty": freq_penalty,
		"max_tokens": max_tokens,
		"presence_penalty": presence_penalty,
		"stream": stream,
		"temperature": temp
	})

	# Send the HTTP request
	var error: int = _chat_http_request.request(_chat_endpoint, _chat_headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		push_error("An error occurred in the HTTP request.")


# Send text response to TTS module to get audio response
func call_tts(text: String) -> void:
	match Globals.tts:
		0:
			_call_ElevenLabs_tts(text)
		1:
			_call_GoogleCloud_tts(text)
		2:
			pass
		_:
			pass


func _call_ElevenLabs_tts(text: String) -> void:
	var body = JSON.stringify({
		"text": text,
		"model_id": "eleven_flash_v2_5",
		"language_code": "en",
		"voice_settings": {"stability": 0, "similarity_boost": 0}
	})

	_tts_http_request.request(_tts_endpoint, _tts_headers, HTTPClient.METHOD_POST, body)


func _call_GoogleCloud_tts(text: String) -> void:
	pass


func _on_stt_request_completed(result, response_code, request_headers, body) -> void:
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("STT request timed out!")
		return
	
	if response_code != 200:
		printerr("STT request failed!")
		print("There was an error with Google Cloud's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())
		return
	
	# Parse the response
	var no_alternatives = true
	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()

	# Check if there is a transcription
	if response.get("results"):
		var generated_transcript = ""
		for e in response["results"]:
			if e.get("alternatives"):
				if e["alternatives"][0].get("transcript"):
					no_alternatives = false
					generated_transcript += e["alternatives"][0]["transcript"]
		if not no_alternatives:
			transcript.append_text("Doctor: " + generated_transcript + "\n")

			call_llm(generated_transcript)

	# No audio was detected
	else:
		print("STT: No audio detected...")
	
	# Audio was detected but could not be transcribed
	if no_alternatives:
		print("STT: Audio unintelligible...")


func _on_llm_request_completed(result, response_code, request_headers, body) -> void:
	# Check if the HTTP request timed out
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("ChatGPT request timed out!")
		# _is_calling_chatgpt = false
		# failed_retrieve_patient_response.emit()
		return
	
	# Check if there was an error in the HTTP request response
	if response_code != 200:
		print("There was an error with ChatGPT's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())
		# _is_calling_chatgpt = false
		# failed_retrieve_patient_response.emit()
		return

	# Parse and retrieve the patient AI response
	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	var message = response["choices"][0]["message"]

	# Append the text to _messages for submission to ChatGPT and _convo for storage to a local transcript
	_messages.append({
		"role": "assistant",
		"content": message["content"]
	})
	# _convo.append({
	# 	"role": "Patient",
	# 	"content": message["content"]
	# })

	transcript.append_text("Patient: " + message["content"] + "\n")

	# DEBUG
	# for msg in _messages:
	# 	print(msg["content"])
	
	# Signal that a response was received from the patient AI
	# _is_calling_chatgpt = false
	# received_patient_response.emit()

	# DEBUG
	# print("Consultee response: " + message_text)

	# # Send the response to a TTS service
	call_tts(message["content"])

	# # Save a local transcript of the conversation
	# save_convo()



func _on_tts_request_completed(result, response_code, request_headers, body) -> void:
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("ElevenLabs request timed out!")
		return
	
	if response_code != 200:
		printerr("There was an error with ElevenLabs' response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())
		return

	_stored_streamed_audio.append_array(body)

	var elevenlabs_stream: AudioStreamMP3 = AudioStreamMP3.new()
	elevenlabs_stream.data = _stored_streamed_audio

	_tts_audio_stream_player.set_stream(elevenlabs_stream)
	_tts_audio_stream_player.play()
	# _stored_streamed_audio.resize(0)
