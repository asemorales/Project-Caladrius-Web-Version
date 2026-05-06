extends Node2D

signal module_complete(module, data1, data2, success_bool, fail_reason)
signal temp_stop # TEMPORARY TO PREVENT ERRORS WHILE MODIFYING CODE TO USE DATABASE 2.0

var patient_model
@export var freq_penalty: float = 0
@export var max_tokens: int = 1024
@export var presence_penalty: float = 0
@export var stream: bool = false
@export var temp: float = 1

# STT
var _stt_http_request: HTTPRequest
var _stt_endpoint: String
var _stt_headers: PackedStringArray
var _lang_code: String
var _stt_audio_stream_player : AudioStreamPlayer2D
var _stt_audio_effect: AudioEffect
var _mix_rate: float
var _stt_audio = null
var _on_audio_loaded_callback = null
var _on_transcript_loaded_callback = null

var _interacted = false

var _stt_input
var _stt_fails = 0

# Embeddings
var _embed_http_request: HTTPRequest
var _embed_endpoint: String
var _embed_headers: PackedStringArray

var _embed_input
var _embed_fails = 0

# Patient LLM
var _chat_http_request: HTTPRequest
var _chat_endpoint: String = "https://api.openai.com/v1/chat/completions"
var _chat_model: String = "ft:gpt-4o-mini-2024-07-18:ateneo-school-of-medicine-and-public-health:patient-eng-v11:Bb0jj7Oz"
var _chat_headers: PackedStringArray
var _chat_user_prompt = ""
var _messages = []
var _cleaned_messages = []
var _chat_convo = []
var _chat_context = []

var _chat_input
var _chat_fails = 0

# Mentor LLM
var _mentor_http_request: HTTPRequest
var _mentor_endpoint: String = "https://api.openai.com/v1/chat/completions"
var _mentor_model: String = "ft:gpt-4o-mini-2024-07-18:ateneo-school-of-medicine-and-public-health:mentor-v6:AjArl35r"
var _mentor_headers: PackedStringArray
var _mentor_user_prompt = ""
var _mentor_messages = []
var _mentor_convo = []
var _mentor_context = []
var _mentor_fields
var _mentor_score

var _mentor_input
var _mentor_fails = 0

# Mentor LLM Scoring
var _order_fields = []
var intro_started = false
var intro_first = true
var closing_done = false
var closed = false
var prev_order = -1
var current_order = -1
var scores = ""
var fields = ""
var formatted_scores

# TTS
var _tts_http_request: HTTPRequest
var _tts_endpoint: String
var _tts_headers: PackedStringArray
var _tts_audio_stream_player: AudioStreamPlayer2D
var _tts_text = ""

var _tts_input
var _tts_fails = 0

var _stored_streamed_audio: PackedByteArray

var _elevenlabs_voice_id_male: String = "IKne3meq5aSn9XLyUdCD"
var _elevenlabs_voice_id_female: String = "EXAVITQu4vr4xnSDxMaL"

@onready var enter_here: TextEdit = $CanvasLayer/HBoxContainer/CenterContainer/MarginContainer/EnterHere
@onready var transcript: RichTextLabel = $CanvasLayer/CenterContainer2/VBoxContainer/MarginContainer/Transcript
@onready var mentor_comment: RichTextLabel = $CanvasLayer/CenterContainer2/VBoxContainer/MarginContainer2/MarginContainer/VBoxContainer/MentorComment


func _ready() -> void:
	await Globals.secrets_loaded
	await Globals.patient_data_loaded
	# await temp_stop	# TEMPORARY TO PREVENT ERRORS WHILE MODIFYING CODE TO USE DATABASE 2.0
	
	# STT
	# HTTPRequest Node
	_stt_http_request = HTTPRequest.new()
	add_child(_stt_http_request)
	_stt_http_request.timeout = 20
	_stt_http_request.request_completed.connect(_on_stt_request_completed)

	# Audio Stream Player to record the player's voice
	_stt_audio_stream_player = AudioStreamPlayer2D.new()
	_stt_audio_stream_player.stream = AudioStreamMicrophone.new()
	_stt_audio_stream_player.set_bus("Record")
	add_child(_stt_audio_stream_player)

	# Setup recording
	var idx = AudioServer.get_bus_index("Record")
	_stt_audio_effect = AudioServer.get_bus_effect(idx, 0)

	_mix_rate = AudioServer.get_mix_rate()
	_mix_rate = clamp(_mix_rate, 8000, 48000)

	# Setup Godot <-> Browser comms for recording the player's voice
	_on_audio_loaded_callback = JavaScriptBridge.create_callback(_on_audio_loaded)
	var audio_callback: JavaScriptObject = JavaScriptBridge.get_interface("audio_callback")
	audio_callback.dataLoaded = _on_audio_loaded_callback

	# Setup Godot <-> Browser comms for retrieving the transcript of the player's voice
	_on_transcript_loaded_callback = JavaScriptBridge.create_callback(_on_transcript_loaded)
	var transcript_callback: JavaScriptObject = JavaScriptBridge.get_interface("transcript_callback")
	transcript_callback.dataLoaded = _on_transcript_loaded_callback
	
	# Setup handling of errors in any module
	module_complete.connect(handleFailsafe)
	
	# Embeddings
	_embed_http_request = HTTPRequest.new()
	add_child(_embed_http_request)
	_embed_http_request.timeout = 20
	_embed_http_request.request_completed.connect(_on_embeddings_request_completed)

	# Patient LLM
	# HTTPRequest Node
	_chat_http_request = HTTPRequest.new()
	add_child(_chat_http_request)
	_chat_http_request.timeout = 20
	_chat_http_request.request_completed.connect(_on_patient_llm_request_completed)

	# Mentor LLM
	# HTTPRequest Node
	_mentor_http_request = HTTPRequest.new()
	add_child(_mentor_http_request)
	_mentor_http_request.timeout = 20
	_mentor_http_request.request_completed.connect(_on_mentor_llm_request_completed)

	# Setup prompts for the mentor (NOT RAG)
	print("Loading mentor context...")
	_load_mentor_context()
	
	# Mentor LLM Scoring
	var field_boundaries: Array = [0, 5, 25, 28, 33, 37, 43, 48, 57, 61, 67, 78, 90, 95, 100, 108, 113, 119, 132, 145, 152, 161, 171, 179, 190, 215, 216, 218]
	_order_fields = []
	for i in range(1, len(field_boundaries)):
		_order_fields.append(Globals.patient.data.keys().slice(field_boundaries[i-1], field_boundaries[i]))

	# Setup fields used for scoring by the mentor AI
	# print("Setting up mentor fields for grading...")
	# _get_mentor_fields()

	# TTS
	# HTTPRequest Node
	_tts_http_request = HTTPRequest.new()
	add_child(_tts_http_request)
	_tts_http_request.timeout = 20
	_tts_http_request.request_completed.connect(_on_tts_request_completed)

	# AudioStreamPlayer for playing the patient's voice
	_tts_audio_stream_player = AudioStreamPlayer2D.new()
	add_child(_tts_audio_stream_player)

	print("Initial setup completed! Setting up modules...")

	# Setup stt, embeddings, llm, and tts modules
	_setup_modules()


# TO BE DEPRECATED IN FAVOR OF A UI BUTTON
func _process(_delta: float) -> void:
	if not _interacted and Input.is_action_just_pressed("Record"):
		JavaScriptBridge.eval("startRecording();")
	elif not _interacted and Input.is_action_just_released("Record"):
		JavaScriptBridge.eval("stopRecording();")
		_interacted = true


# Holds the logic for what to do when a module fails
func handleFailsafe(module, data, data2, success, reason) -> void:
	match module:
		"stt":
			if not success and _stt_fails < 3:
				printerr("STT module failed!")

				# Inform user STT failed
				if reason == "Unintelligible":
					transcript.append_text("[System]: Speech-to-Text module detected unintelligible audio. Please try again.\n")
					return
				elif reason == "No Audio":
					transcript.append_text("[System]: Speech-to-Text module failed to detect audio. Please try again.\n")
					return
				
				if reason == "Timed Out":
					transcript.append_text("[System]: Speech-to-Text module timed out. Retrying...\n")
				else:
					transcript.append_text("[System]: Speech-to-Text module failed to transcribe the audio. Retrying...\n")

				_stt_fails += 1

				# Retry sending STT
				call_stt(data)
			elif success:
				_stt_fails = 0
			
			if _stt_fails >= 3:
				_interacted = false
				_stt_fails = 0

				patient_model.play_idle()
				patient_model.face.stop()
				patient_model.face_play_default()

				transcript.append_text("[System]: Speech-to-Text module failed to transcribe the audio. Please try again.\n")
		"embed":
			if not success and _embed_fails < 3:
				printerr("Embeddings module failed!")

				if reason == "Timed Out":
					transcript.append_text("[System]: Embeddings module timed out. Retrying...\n")
				else:
					transcript.append_text("[System]: Embeddings module failed to generate embeddings. Retrying...\n")

				_embed_fails += 1

				# Retry sending STT
				call_embeddings(data)
			elif success:
				_embed_fails = 0
			
			if _embed_fails >= 3:
				_interacted = false
				_embed_fails = 0

				patient_model.play_idle()
				patient_model.face.stop()
				patient_model.face_play_default()

				transcript.append_text("[System]: Embeddings module failed to generate embeddings. Please try again.\n")
		"chat":
			if not success and _chat_fails < 3:
				printerr("Chat module failed!")
				
				# Inform user chat LLM failed
				if reason == "Timed Out":
					transcript.append_text("[System]: Patient AI timed out. Retrying...\n")
				else:
					transcript.append_text("[System]: Patient AI failed to generate a response. Retrying...\n")

				_chat_fails += 1
				
				# Retry sending chat LLM
				call_llm(data)
			elif success:
				_chat_fails = 0
			
			if _chat_fails >= 3:
				_interacted = false
				_chat_fails = 0

				patient_model.play_idle()
				patient_model.face.stop()
				patient_model.face_play_default()

				transcript.append_text("[System]: Patient AI failed to generate a response. Please try again.\n")
		"mentor":
			printerr("Mentor module failed!")
			if not success:
				pass
				
				# (Optionally) inform user mentor LLM failed
				
				# Retry sending request to mentor LLM
		"tts":
			if not success and _tts_fails < 3:
				printerr("TTS module failed!")
				
				# Inform user TTS failed
				if reason == "Timed Out":
					transcript.append_text("[System]: Text-to-Speech module timed out. Retrying...\n")
				else:
					transcript.append_text("[System]: Text-to-Speech module failed to generate audio. Retrying...\n")

				_tts_fails += 1
				
				# Retry sending TTS
				call_tts(data)
			elif success:
				_tts_fails = 0

			if _tts_fails >= 3:
				_interacted = false
				_tts_fails = 0
				transcript.append_text("[System]: Text-to-Speech module failed to generate audio after 3 attempts. Stopping TTS.\n")
				
				patient_model.play_idle()
				patient_model.face.stop()
				patient_model.face_play_default()
		_:
			push_error("Unknown module failed: " + module)


func _setup_modules() -> void:
	_setup_stt()
	_setup_embeddings()
	_setup_llm()
	_setup_tts()


func _setup_stt() -> void:
	match Globals.stt:
		0: # Google Cloud v1
			_stt_endpoint = "https://speech.googleapis.com/v1/speech:recognize?key=" + Globals.api_keys["GoogleCloud"]
			_stt_headers = PackedStringArray(["Content-Type: audio/webm", "accept: */*"])
		1: # Google Cloud v2
			match Globals.language:
				0:
					_stt_endpoint = "https://asia-southeast1-speech.googleapis.com/v2/projects/spatial-ship-433309-m0/locations/asia-southeast1/recognizers/godot-asmph-recognizer-eng:recognize"
				1:
					_stt_endpoint = "https://asia-southeast1-speech.googleapis.com/v2/projects/spatial-ship-433309-m0/locations/asia-southeast1/recognizers/godot-asmph-recognizer-fil:recognize"
				_: # Default to English
					_stt_endpoint = "https://asia-southeast1-speech.googleapis.com/v2/projects/spatial-ship-433309-m0/locations/asia-southeast1/recognizers/godot-asmph-recognizer-eng:recognize"
			
			_lang_code = "en-US" if Globals.language == 0 else "fil-PH"
			_stt_headers = PackedStringArray(["Authorization: Bearer " + Globals.google_auth_token, "Content-Type: audio/webm", "accept: */*", "Format: WEBM_OPUS"])
		2: # Local / Godot STT; NOT IMPLEMENTED
			_stt_endpoint = ""
			_stt_headers = PackedStringArray([])
		_:
			push_error("Invalid STT option!")


func _setup_embeddings() -> void:
	match Globals.embed:
		0:
			pass
		1:
			_embed_endpoint = "https://api.openai.com/v1/embeddings"
			_embed_headers = PackedStringArray(["Content-type: application/json", "Authorization: Bearer " + Globals.api_keys["ChatGPT"]])
		_:
			push_error("Invalid embeddings option!")


func _setup_llm() -> void:
	# Patient LLM
	_chat_headers = PackedStringArray(["Content-type: application/json", "Authorization: Bearer " + Globals.api_keys["ChatGPT"]])

	# Mentor LLM
	_mentor_headers = PackedStringArray(["Content-type: application/json", "Authorization: Bearer " + Globals.api_keys["ChatGPT"]])


func _setup_tts() -> void:
	match Globals.tts:
		0: # ElevenLabs
			_tts_endpoint = "https://api.elevenlabs.io/v1/text-to-speech/" + _elevenlabs_voice_id_female
			_tts_headers = PackedStringArray(["accept: audio/mpeg", "xi-api-key: " + Globals.api_keys["ElevenLabs"], "Content-Type: application/json"])
		1: # Google Cloud
			_tts_endpoint = "https://texttospeech.googleapis.com/v1/text:synthesize?key=" + Globals.api_keys["GoogleCloud"]
			_tts_headers = PackedStringArray(["accept: */*", "xi-api-key: " + Globals.api_keys["GoogleCloud"], "Content-Type: application/json"])
		2: # Godot TTS; NOT IMPLEMENTED
			_tts_endpoint = ""
			_tts_headers = PackedStringArray([])
		_:
			push_error("Invalid TTS option!")


func _on_enter_button_pressed() -> void:
	if not _interacted and enter_here.text != "":
		_interacted = true
		
		transcript.append_text("[b]DOCTOR:[/b] " + enter_here.text + "\n")

		_embed_input = enter_here.text
		call_embeddings(enter_here.text)

		enter_here.text = ""


# Called when the browser finishes recording the player's voice
func _on_audio_loaded(data: Array) -> void:
	if data.size() == 0:
		printerr("Audio data array retrieved from the browser is empty!")
		return
	
	var json: JSON = JSON.new()
	var json_parse_result: int = json.parse(data[0])
	if not json_parse_result == OK:
		push_error("Audio data retrieved from the browser can't be parsed as a json object!")
		return
	
	var dup = json.data.duplicate(true)
	_stt_input = dup["audio"]
	call_stt(dup["audio"])


## Send audio to STT module to get the transcript
func call_stt(audio) -> void:
	match Globals.stt:
		0:
			print("Calling Google Cloud v1 STT")
			_call_GoogleCloud_v1_stt(audio)
		1:
			print("Calling Google Cloud v2 STT")
			_call_GoogleCloud_v2_stt(audio)
		2:
			pass
		_:
			push_error("Invalid STT setting!")


func _call_GoogleCloud_v1_stt(audio) -> void:
	JavaScriptBridge.eval("""callGoogleSTTv1(\'%s\', \'%d\', \'%s\');""" % [audio, _mix_rate, Globals.api_keys["GoogleCloud"]])


func _call_GoogleCloud_v2_stt(audio) -> void:
	JavaScriptBridge.eval("""callGoogleSTTv2(\'%s\', \'%s\', \'%d\', \'%s\', \'%s\');""" % [_stt_endpoint, _lang_code, _mix_rate, audio, Globals.google_auth_token])


# Unused
func _on_stt_request_completed(result, response_code, request_headers, body) -> void:
	transcript.append_text("[b]DOCTOR:[/b] " + result + "\n")


func _on_transcript_loaded(data: Array) -> void:
	if data.size() == 0:
		printerr("Transcript data array retrieved from the browser is empty!")
		return
	
	var json: JSON = JSON.new()
	var json_parse_result: int = json.parse(data[0])
	if not json_parse_result == OK:
		push_error("Transcript data retrieved from the browser can't be parsed as a json object!")
		return
	
	var dup = json.data.duplicate(true)

	match dup["result"]:
		"No Audio":
			print("No audio detected in the recording!")
			module_complete.emit("stt", _stt_audio, false, "No Audio")
		"Unintelligible":
			print("Audio is unintelligible!")
			module_complete.emit("stt", _stt_audio, false, "Unintelligible")
		_:
			# Transcript was successfully generated
			module_complete.emit("stt", _stt_audio, true, null)
			transcript.append_text("[b]DOCTOR:[/b] " + dup["result"] + "\n")
			
			_embed_input = dup["result"]
			call_embeddings(dup["result"])


func call_embeddings(text: String) -> void:
	_call_openai_embeddings(text)


func _call_openai_embeddings(text: String) -> void:
	# Build the HTTP request body
	var body: String = JSON.stringify({
		"model": "text-embedding-3-small",
		"input": text,
		"encoding_format": "float"
	})

	# Send the request
	var error: int = _embed_http_request.request(_embed_endpoint, _embed_headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		printerr("An error occurred in the Embeddings HTTP request!")


func _on_embeddings_request_completed(result, response_code, request_headers, body) -> void:
	# Check if the HTTP request timed out
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("Embeddings HTTP request timed out!")

		module_complete.emit("embed", _chat_user_prompt, false, "Timed Out")
		return
	
	# Check if there was an error in the HTTP request response
	if response_code != 200:
		printerr("There was an error with the Patient LLM ChatGPT's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())

		module_complete.emit("embed", _chat_user_prompt, false, "General Error")
		return
	
	# Parse and retrieve the embedding
	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	var embedding = response["data"][0]["embedding"]
	print(embedding)

	_chat_input = _embed_input
	# call_llm(_chat_input) TEMPORARILY COMMENTED


## Sends text to the llm module to receive a response
func call_llm(text: String) -> void:
	_chat_user_prompt = text

	_call_ChatGPT(text)
	# _call_mentor(text) # TEMPORARILY DISABLE THE MENTOR AI


# Sends text to ChatGPT to receive a response
func _call_ChatGPT(text: String) -> void:
	patient_model.play_thinking()
	
	# Get vector representation of the user prompt via GloVe
	var vector: Array = _get_string_vector(text)
	var matching_vectors: Array = _get_closest_matches(vector, 20)
	var matching_headers: Array = []
	for match in matching_vectors:
		var header = match[2]
		matching_headers.append(header)
	
	print("Matching Headers: " + str(matching_headers))
	# _interacted = false # DEBUG
	# return # DEBUG

	# Reset messages to remove previously inserted context
	_messages = _cleaned_messages.duplicate(true)

	# Add context retrieved via GloVe-RAG implementation
	for header in matching_headers:
		var context_index: int = Globals.patient.to_index(header)
		if context_index < _chat_context.size() and not _chat_context[context_index].size() == 0:
			_messages.append(_chat_context[context_index])
			print(_chat_context[context_index])
	
	# Always add this to minimize doctor hallucinations
	_messages.append({"role": "system", "content": 'You are roleplaying as a patient who is visiting the doctor for a consultation. You are speaking to the user who is the doctor. You will be responding to the questions asked by the user. Do not respond along the lines of "How may I assist you?" or "How can I help you?". Act like a patient visiting the doctor for a consultation.'})

	# Append the text to _messages for submission to ChatGPT
	_messages.append({
		"role": "user",
		"content": text
	})
	# Keep a copy of the messages sent to ChatGPT but without the added contexts
	_cleaned_messages.append({
		"role": "user",
		"content": text
	})
	# Keep a copy of the conversation containing only the messages that are visible to the user for saving
	_chat_convo.append({
		"role": "User",
		"content": text
	})

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
		printerr("An error occurred in the Patient LLM HTTP request!")


func _call_mentor(text: String) -> void:
	# Ensure the mentor only grades the currently prompt sent by the user
	_mentor_messages = _mentor_context.duplicate(true)
	_mentor_messages.append({
		"role": "user",
		"content": text
	})

	# Keep a copy of messages that are visible to the user and are sent by them
	_mentor_convo.append({
		"role": "user",
		"content": text
	})

	# Build the body of the HTTP request
	var body: String = JSON.stringify({
		"messages": _mentor_messages,
		"model": _mentor_model,
		"frequency_penalty": freq_penalty,
		"max_tokens": max_tokens,
		"presence_penalty": presence_penalty,
		"stream": stream,
		"temperature": temp
	})

	# Send the request
	var error: int = _mentor_http_request.request(_mentor_endpoint, _mentor_headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		printerr("An error occurred in the Mentor LLM HTTP request!")


func _on_patient_llm_request_completed(result, response_code, request_headers, body) -> void:
	# Check if the HTTP request timed out
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("ChatGPT HTTP request timed out!")

		module_complete.emit("chat", _chat_user_prompt, false)
		return
	
	# Check if there was an error in the HTTP request response
	if response_code != 200:
		printerr("There was an error with the Patient LLM ChatGPT's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())

		module_complete.emit("chat", _chat_user_prompt, false)
		return

	# Parse and retrieve the patient AI response
	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	var message = response["choices"][0]["message"]

	# Append the response to _messages for submission to ChatGPT
	_messages.append({
		"role": "assistant",
		"content": message["content"]
	})
	# Keep a copy of the conversation without the context
	_cleaned_messages.append({
		"role": "assistant",
		"content": message["content"]
	})
	# Keep a copy of the conversation only containing messages visible to the player
	_chat_convo.append({
		"role": "Patient",
		"content": message["content"]
	})

	transcript.append_text("[b]PATIENT:[/b] " + message["content"] + "\n")

	module_complete.emit("chat", _chat_user_prompt, true)
	
	# Send the response to the TTS module
	call_tts(message["content"])


func _on_mentor_llm_request_completed(result, response_code, request_headers, body) -> void:
	# Check if the HTTP request timed out
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("Mentor AI HTTP request timed out!")
		return
	
	# Check if there was an error in the HTTP request response
	if response_code != 200:
		printerr("There was an error with the Mentor LLM ChatGPT's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())
		return

	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	var message = response["choices"][0]["message"]

	mentor_comment.text = message["content"]

	# Save to a copy of the mentor conversation to be saved
	_mentor_convo.append({
		"role": "assistant",
		"content": message["content"]
	})
	
	# Grade the response based on the mentor's response
	_grade_response(message["content"])


# Send text response to TTS module to get audio response
func call_tts(text: String) -> void:
	_tts_text = text

	match Globals.tts:
		0:
			_call_ElevenLabs_tts(text)
		1:
			_call_GoogleCloud_tts(text)
		2:
			pass
		_:
			push_error("Invalid TTS setting!")


func _call_ElevenLabs_tts(text: String) -> void:
	# Build the HTTP request body
	var body = JSON.stringify({
		"text": text,
		"model_id": "eleven_flash_v2_5",
		"language_code": "en",
		"voice_settings": {"stability": 0, "similarity_boost": 0}
	})

	# Send the request
	var error: int = _tts_http_request.request(_tts_endpoint, _tts_headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		printerr("An error occurred in the ElevenLabs TTS HTTP request!")


func _call_GoogleCloud_tts(text: String) -> void:
	# Build the HTTP request body
	var body = JSON.stringify({
		"input": {
			"text": text
		},
		"voice": {
			"languageCode": "fil-PH",
			"name": "fil-PH-Wavenet-A",
			"ssmlGender": "FEMALE"
		},
		"audioConfig": {
			"audioEncoding": "MP3"
		}
	})
	
	# Send the request
	var error: int = _tts_http_request.request(_tts_endpoint, _tts_headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		printerr("An error occurred in the Google Cloud TTS HTTP request!")


func _on_tts_request_completed(result, response_code, request_headers, body) -> void:
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("TTS request timed out!")
		module_complete.emit("tts", _tts_text, false)
		return
	
	if response_code != 200:
		printerr("There was an error with the TTS module's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())
		module_complete.emit("tts", _tts_text, false)
		return

	module_complete.emit("tts", _tts_text, true)

	_stored_streamed_audio.clear()
	_stored_streamed_audio.append_array(body)

	var audio_stream: AudioStreamMP3 = AudioStreamMP3.new()
	audio_stream.data = _stored_streamed_audio

	_tts_audio_stream_player.set_stream(audio_stream)
	_tts_audio_stream_player.play()
	
	patient_model.play_idle()
	patient_model.face_play_talking()
	
	await _tts_audio_stream_player.finished
	
	patient_model.face.stop()
	patient_model.face_play_default()
	# _stored_streamed_audio.resize(0)

	_interacted = false


# For GloVe-RAG use
func _get_closest_matches(vector: Array, n: int) -> Array:
	var matches: Array = []

	var sorted_vectors: Array = _sort_header_vectors(vector)

	if n < sorted_vectors.size():
		matches.append_array(sorted_vectors.slice(0, n))
	else:
		matches = sorted_vectors

	return matches


# For GloVe-RAG use
func _sort_header_vectors(arr: Array) -> Array:
	var headers = Embeddings.header_embeddings_data.keys()
	var sorting_vectors: Array = []
	for header in headers:
		if not Embeddings.header_embeddings_data[header].size() == arr.size():
			print("Header's vector has size mismatch! Skipping vector...")
			continue
		sorting_vectors.append([_euclidean_distance(Embeddings.header_embeddings_data[header], arr), Embeddings.header_embeddings_data[header], header])

	for item in sorting_vectors:
		if item.size() != 3:
			push_error("A header's item has size mismatch in sorting vectors!")
	var sorted_vectors = _quicksort(sorting_vectors)

	return sorted_vectors


# TODO: modify to allow use with OpenAI embeddings
# For GloVe-RAG use
func _quicksort(arr: Array) -> Array:
	# Base Case
	if arr.size() <= 1:
		return arr
	if arr.size() == 2:
		if arr[0][0] > arr[1][0]:
			return [arr[1], arr[0]]
		else:
			return arr

	# Make a copy of the array and select a random pivot
	var copy = arr.duplicate(true)
	var pivot = copy.pick_random()

	# Split the array into two
	var left: Array = []
	var middle: Array = []
	var right: Array = []

	for item in copy:
		if item.size() != 3:
			push_error("Item to quick sort has size mismatch!")

		if item[0] == pivot[0]:
			middle.append(item)
		elif item[0] < pivot[0]:
			left.append(item)
		else:
			right.append(item)

	for item in left:
		if item.size() != 3:
			push_error("Item to quick sort has size mismatch in left array!")
	for item in middle:
		if item.size() != 3:
			push_error("Item to quick sort has size mismatch in middle array!")
	for item in right:
		if item.size() != 3:
			push_error("Item to quick sort has size mismatch in right array!")

	var sorted_left = _quicksort(left)
	var sorted_right = _quicksort(right)

	var sorted: Array = []
	for item in sorted_left:
		sorted.append(item)
	for item in middle:
		sorted.append(item)
	for item in sorted_right:
		sorted.append(item)

	return sorted


# For either GloVe-RAG or OpenAI embeddings use
func _euclidean_distance(vec1: Array, vec2: Array) -> float:
	assert (vec1.size() == vec2.size(), "Vectors are of different sizes. Can't calculate euclidean distance!")

	var distance: float = 0
	for i in range(vec1.size()):
		distance += pow(vec1[i] - vec2[i], 2)
	
	return sqrt(abs(distance))


# For GloVe-RAG use
func _tokenize(string: String) -> Array:
	var tokens: Array = []

	var regex: RegEx = RegEx.new()
	regex.compile("\\.+|-+|''|\"\"|n't|'s|'re|'ve|'m|'ll|'d|[0-9]*\\.[0-9]+|'[0-9]*[a-zA-Z]*|[0-9]+[a-zA-Z]+|[0-9]+ [0-9]+\\/[0-9]+|[0-9]{2}:[0-9]{2}|mr\\.|ms\\.|mrs\\.|mx\\.|dr\\.|jr\\.|sr\\.|[^a-zA-Z0-9 ]|[a-zA-Z]+|[0-9]+")

	var words: Array = Array(string.split(" "))
	for word: String in words:
		var matches: Array = regex.search_all(word)

		for match: RegExMatch in matches:
			var token: String = word.substr(match.get_start(), match.get_end() - match.get_start())
			tokens.append(token)

	return tokens


# For GloVe-RAG use
func _get_string_vector(string: String) -> Array:
	var vector: Array = []
	var words: Array = _tokenize(string.to_lower())

	var average: int = 0
	for word in words:
		var word_vector: Array = _get_word_vector(word)
		if word_vector.size() == 0:
			continue
		elif vector.size() == 0:
			vector = word_vector

			average += 1
		else:
			assert (vector.size() == word_vector.size())

			for i in range(vector.size()):
				vector[i] += word_vector[i]
			average += 1
	
	for i in range(vector.size()):
		vector[i] /= average
	
	return vector


# For GloVe-RAG use
func _get_word_vector(word: String) -> Array:
	if word in Embeddings.data:
		return Embeddings.data[word]
	else:
		return []


func load_patient_model(age : int, sex : String) -> void:
	var patient
	if age < 50:
		if sex == "Male":
			patient = load("res://src/patient-interview-scenes/adult_male_patient.tscn")
		if sex == "Female":
			patient = load("res://src/patient-interview-scenes/adult_female_patient.tscn")
	elif age >= 50:
		if sex == "Male":
			patient = load("res://src/patient-interview-scenes/old_male_patient.tscn")
		if sex == "Female":
			patient = load("res://src/patient-interview-scenes/old_female_patient.tscn")
	
	patient_model = patient.instantiate()
	add_child(patient_model)
	patient_model.scale = Vector2(2, 2)
	patient_model.position = Vector2(500, 990)


func _load_mentor_context() -> void:
	_mentor_context = [
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'How old are you and how would you rank the your pain?'}, {'role': 'assistant', 'content': 'Age:1; Severity:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have nausea or vomiting?'}, {'role': 'assistant', 'content': 'Nausea:1; Vomiting:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have headaches or soreness'}, {'role': 'assistant', 'content': 'Headache:1; Sores:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Are you itchy or rashy like a weirdo?'}, {'role': 'assistant', 'content': 'Itching:0.5; Rashes:0.5; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Are you like deaf or something or do you have ringing in your ears like a crazy person?'}, {'role': 'assistant', 'content': 'Deafness:0.5; Tinnitus:0.5; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Are you bleeding from your nose or from your vagina?'}, {'role': 'assistant', 'content': 'Nosebleeds:0.5; Last Menstrual Period (YYYY-MM-DD):0.5; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'What are your other general symptoms or additional details regarding your history?'}, {'role': 'assistant', 'content': 'Other General Symptoms:1; Additional Details Regarding History:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Have you gained or lost weight recently?'}, {'role': 'assistant', 'content': 'Weight Gain:1; Weight Loss:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'When is your birthday and how old are you?'}, {'role': 'assistant', 'content': 'Birthday (YYYY-MM-DD):1; Age:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Is your asshole bleeding or are you peeing out blood?'}, {'role': 'assistant', 'content': 'Rectal Bleeding:0.5; Hematuria:0.5; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Are you intolerant to heat or cold?'}, {'role': 'assistant', 'content': 'Heat Intolerance:1; Cold Intolerance:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Does your family have history of tuberculosis or asthma?'}, {'role': 'assistant', 'content': 'Family History of Tuberculosis:1; Family History of Asthma:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you or your family have history of cancer?'}, {'role': 'assistant', 'content': 'History of Cancer:1; Family History of Cancer:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you or your family have history of tuberculosis?'}, {'role': 'assistant', 'content': 'History of Tuberculosis:1; Family History of Tuberculosis:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you or your family have history of asthma?'}, {'role': 'assistant', 'content': 'History of Asthma:1; Family History of Asthma:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you or your family have history of psychiatric consult?'}, {'role': 'assistant', 'content': 'History of Psychiatric Consult:1; Family History of Psychiatric Consult:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you or your family have history of diabetes?'}, {'role': 'assistant', 'content': 'History of Diabetes:1; Family History of Diabetes:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you or your family have history of heart disease?'}, {'role': 'assistant', 'content': 'History of Cardiovascular Disease:1; Family History of Cardiovascular Disease:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you or your family have history of cardiovascular disease?'}, {'role': 'assistant', 'content': 'History of Cardiovascular Disease:1; Family History of Cardiovascular Disease:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have fever, weight gain, or weight loss?'}, {'role': 'assistant', 'content': 'Fever:1; Weight Gain:1; Weight Loss:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have weakness, fatigue, or rashes?'}, {'role': 'assistant', 'content': 'Weakness:1; Fatigue:1; Rashes:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have lumps, sores, or itching?'}, {'role': 'assistant', 'content': 'Lumps:1; Sores:1; Itching:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have muscle pains, joint pains, or changes in skin color?'}, {'role': 'assistant', 'content': 'Muscle Pains:1; Joint Pains:1; Changes in Skin Color:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have changes in hair, or gout, or headaches?'}, {'role': 'assistant', 'content': 'Changes in Hair/Nails:1; Gout:1; Headache:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have headache, dizziness, or blurring of vision?'}, {'role': 'assistant', 'content': 'Headache:1; Dizziness:1; Blurring of Vision:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have tinnitus, deafness, or nosebleeds?'}, {'role': 'assistant', 'content': 'Tinnitus:1; Deafness:1; Nosebleeds:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have frequent colds, hoarseness, or dry mouth?'}, {'role': 'assistant', 'content': 'Frequent Colds:1; Hoarseness:1; Dry Mouth:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have dyspnea, hemoptysis, cough, or wheezing?'}, {'role': 'assistant', 'content': 'Dyspnea:1; Hemoptysis:1; Cough:1; Wheezing:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have palpitations, chest pains, syncope, or orthopnea?'}, {'role': 'assistant', 'content': 'Palpitations:1; Chest Pains:1; Syncope:1; Orthopnea:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have nausea, vomiting, dysphagia, or heartburn?'}, {'role': 'assistant', 'content': 'Nausea:1; Vomiting:1; Dysphagia:1; Heartburn:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have changes in bowel habits, rectal bleeding, or jaundice?'}, {'role': 'assistant', 'content': 'Change in Bowel Habits:1; Rectal Bleeding:1; Jaundice:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you experience nocturia, dysuria, urinary frequency, or hematuria?'}, {'role': 'assistant', 'content': 'Nocturia:1; Dysuria:1; Urinary Frequency:1; Hematuria:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have excessive sweating, heat intolerance, polyuria, excessive thirst, or cold intolerance?'}, {'role': 'assistant', 'content': 'Excessive Sweating:1; Heat Intolerance:1; Polyuria:1; Excessive Thirst:1; Cold Intolerance:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have history of tuberculosis, asthma, diabetes, or hypertension?'}, {'role': 'assistant', 'content': 'History of Tuberculosis:1; History of Asthma:1; History of Diabetes:1; History of Hypertension:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Do you have family history of psychiatric consult, cancer, or allergies?'}, {'role': 'assistant', 'content': 'Family History of Psychiatric Consult:1; Family History of Cancer:1; Family History of Allergies:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Good morning!'}, {'role': 'assistant', 'content': 'Introduction:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "I don't have all day, so let's get to the point"}, {'role': 'assistant', 'content': 'Introduction:0.5'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "I'm Dr. Reyes. Welcome! I'll be working with you to address any questions or concerns you have."}, {'role': 'assistant', 'content': 'Introduction:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "Yeah, I'm Dr. Reyes. Here to figure out what you messed up this time."}, {'role': 'assistant', 'content': 'Introduction:0.5'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "I'm Dr. Reyes. Welcome! What is the purpose of your visit?"}, {'role': 'assistant', 'content': 'Introduction:1; Chief Complaint:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "Yeah, I'm Dr. Reyes. What's wrong with you this time?"}, {'role': 'assistant', 'content': 'Introduction:0.5; Chief Complaint:0.5'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "I'll start by asking a few questions to get a clearer picture of your health and any issues you've noticed. If there's anything specific you'd like to focus on today or any questions you want to make sure we cover, feel free to let me know."}, {'role': 'assistant', 'content': 'Agenda:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "What are the main topics you'd like to discuss today?"}, {'role': 'assistant', 'content': 'Agenda:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "Are there any specific issues or concerns you'd like to address?"}, {'role': 'assistant', 'content': 'Agenda:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "Would you like to set any priorities for today's session?"}, {'role': 'assistant', 'content': 'Agenda:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "Alright, let's make this quick. I'll ask some questions, you answer, and we'll get you out of here."}, {'role': 'assistant', 'content': 'Agenda:0.5'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "I'd like to get your permission before we start, as I'll need to ask some personal health questions and possibly perform a basic examination. Is that alright with you?"}, {'role': 'assistant', 'content': 'Consent:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'I need you to give consent, okay? Just do it so we can move on.'}, {'role': 'assistant', 'content': 'Consent:0.5'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Before we start, I want to assure you that everything we discuss today is completely confidential. Feel free to share any information that you feel is important.'}, {'role': 'assistant', 'content': 'Confidentiality:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Of course, this is confidential. But honestly, who cares what you say, right?'}, {'role': 'assistant', 'content': 'Confidentiality:0.5'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'So you mentioned that you have been experiencing bilateral knee pain for 6 months. Your joints are swelling and you have blurring of vision. You have a history of diabetes and hypertension.'}, {'role': 'assistant', 'content': 'Recap:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "You're still complaining about that rash from last week. You haven't really done anything to fix it. And you're coming back with even worse pain to pester me about."}, {'role': 'assistant', 'content': 'Recap:0.5'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Thank you for coming in today and being open about your concerns. I appreciate your trust in us.'}, {'role': 'assistant', 'content': 'Closing:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "Okay, we're done here. Just try not to think about it too much."}, {'role': 'assistant', 'content': 'Closing:0.5'}, 
		{'role': 'system', 'content': 'The patient has a name. '}, {'role': 'user', 'content': 'What is your name?'}, {'role': 'assistant', 'content': 'Patient First Name:1'}, 
		{'role': 'system', 'content': 'The patient has an attending physician. '}, {'role': 'user', 'content': 'Who is your attending physician?'}, {'role': 'assistant', 'content': 'Attending Physician First Name:1'}, 
		{'role': 'system', 'content': 'The patient has a birthday. '}, {'role': 'user', 'content': 'When is your birthday?'}, {'role': 'assistant', 'content': 'Birthday (YYYY-MM-DD):1'}, 
		{'role': 'system', 'content': 'The patient has an age. '}, {'role': 'user', 'content': 'How old are you?'}, {'role': 'assistant', 'content': 'Age:1'}, 
		{'role': 'system', 'content': 'The patient has a sex (male or female). '}, {'role': 'user', 'content': "What's your sex?"}, {'role': 'assistant', 'content': 'Sex:1'}, 
		{'role': 'system', 'content': 'The patient has an address in the Philippines. '}, {'role': 'user', 'content': 'What is your address.'}, {'role': 'assistant', 'content': 'Address:1'}, 
		{'role': 'system', 'content': 'The patient has a parent/guardian. '}, {'role': 'user', 'content': 'Who is your guardian?'}, {'role': 'assistant', 'content': 'Parent/ Guardian First Name:1'}, 
		{'role': 'system', 'content': 'The patient has an informant. '}, {'role': 'user', 'content': 'Who is your informant?'}, {'role': 'assistant', 'content': 'Informant First Name:1'}, 
		{'role': 'system', 'content': 'The patient has a certain level of reliability ranging from bad to good. '}, {'role': 'user', 'content': 'How reliable are you?'}, {'role': 'assistant', 'content': 'Reliability:1'}, 
		{'role': 'system', 'content': 'The patient has a dwelling type either a house or an apartment. '}, {'role': 'user', 'content': 'What kind of home do you live in?'}, {'role': 'assistant', 'content': 'Dwelling Type (House, Apt.):1'}, 
		{'role': 'system', 'content': 'The patient has a dwelling type that has a number of rooms. '}, {'role': 'user', 'content': 'How many rooms are in your house?'}, {'role': 'assistant', 'content': 'Number Of Rooms:1'}, 
		{'role': 'system', 'content': 'The patient has a number of household members. '}, {'role': 'user', 'content': 'What appliances do you have at your house?'}, {'role': 'assistant', 'content': 'Appliances (Radio, Tv, Refrigerator) *Can Be Multiple:1'}, 
		{'role': 'system', 'content': 'The patient has a dwelling type that has a number of rooms. '}, {'role': 'user', 'content': 'How many people do you live with?'}, {'role': 'assistant', 'content': 'Number Of Household Members:1'}, 
		{'role': 'system', 'content': 'The patient has a mode of transportation (car, jeep, motorcycle, or no transportation). '}, {'role': 'user', 'content': "What's your usual mode of transportation."}, {'role': 'assistant', 'content': 'Transportation (None, Car, Jeep, Motorcycle):1'}, 
		{'role': 'system', 'content': 'The patient has a landline number (11 digits). '}, {'role': 'user', 'content': 'What is your landline number?'}, {'role': 'assistant', 'content': 'Landline Number (11 Digits):1'}, 
		{'role': 'system', 'content': 'The patient has a phone number (12 digits). '}, {'role': 'user', 'content': 'What is your contact number?'}, {'role': 'assistant', 'content': 'Phone Number (12 Digits Starting With 63):1'}, 
		{'role': 'system', 'content': 'The patient has a nationality. '}, {'role': 'user', 'content': 'What is your nationality?'}, {'role': 'assistant', 'content': 'Nationality:1'}, 
		{'role': 'system', 'content': 'The patient has a religion (Roman Catholic, Protestant, Muslim, Iglesia ni Cristo, Aglipay, or Other). '}, {'role': 'user', 'content': 'What is your religion?'}, {'role': 'assistant', 'content': 'Religion:1'}, 
		{'role': 'system', 'content': 'The patient has an annual family income (<50K, 50K-100K, 100K-200K, 200K-300K, >300K). '}, {'role': 'user', 'content': 'How much money does your family earn in a year?'}, {'role': 'assistant', 'content': 'Annual Family Income:1'}, 
		{'role': 'system', 'content': 'The patient has pain and provocations make the pain worse (action, place, or none). '}, {'role': 'user', 'content': 'What worsens your knee pain?'}, {'role': 'assistant', 'content': 'Provocation:1'}, 
		{'role': 'system', 'content': 'The patient has pain and provocations make the pain worse (action, place, or none). '}, {'role': 'user', 'content': 'What triggers your abdominal pain?'}, {'role': 'assistant', 'content': 'Provocation:1'}, 
		{'role': 'system', 'content': 'The patient has pain and provocations make the pain worse (action, place, or none). '}, {'role': 'user', 'content': 'What actions make your headaches worse?'}, {'role': 'assistant', 'content': 'Provocation:1'}, 
		{'role': 'system', 'content': 'The patient has pain and quality describes the pain. (sharp, dull, continuous, throbbing, etc.) . '}, {'role': 'user', 'content': 'How would you describe your headaces?'}, {'role': 'assistant', 'content': 'Quality:1'}, 
		{'role': 'system', 'content': 'The patient has pain and quality describes the pain. (sharp, dull, continuous, throbbing, etc.) . '}, {'role': 'user', 'content': 'What is the quality of your headaches?'}, {'role': 'assistant', 'content': 'Quality:1'}, 
		{'role': 'system', 'content': 'The patient has pain and quality describes the pain. (sharp, dull, continuous, throbbing, etc.) . '}, {'role': 'user', 'content': 'How would you describe your knee pain?'}, {'role': 'assistant', 'content': 'Quality:1'}, 
		{'role': 'system', 'content': 'The patient has pain and quality describes the pain. (sharp, dull, continuous, throbbing, etc.) . '}, {'role': 'user', 'content': 'What is the quality of your abdominal pain?'}, {'role': 'assistant', 'content': 'Quality:1'}, 
		{'role': 'system', 'content': 'The patient has pain and it is located on a specific region on your body. '}, {'role': 'user', 'content': 'Where is your knee pain located?'}, {'role': 'assistant', 'content': 'Region:1'}, 
		{'role': 'system', 'content': 'The patient has pain and it is located on a specific region on your body. '}, {'role': 'user', 'content': 'Where does abdominal pain hurt most?'}, {'role': 'assistant', 'content': 'Region:1'}, 
		{'role': 'system', 'content': 'The patient has pain and it is located on a specific region on your body. '}, {'role': 'user', 'content': 'Where do you feel your abdominal pain?'}, {'role': 'assistant', 'content': 'Region:1'}, 
		{'role': 'system', 'content': 'The patient has pain and it has a severity ranging from 1 to 10. '}, {'role': 'user', 'content': 'How severe is your pain?'}, {'role': 'assistant', 'content': 'Severity:1'}, 
		{'role': 'system', 'content': 'The patient has pain and it has a severity ranging from 1 to 10. '}, {'role': 'user', 'content': 'Can you rank your knee pain?'}, {'role': 'assistant', 'content': 'Severity:1'}, 
		{'role': 'system', 'content': 'The patient has pain and it has a severity ranging from 1 to 10. '}, {'role': 'user', 'content': 'How severe is your abdominal pain?'}, {'role': 'assistant', 'content': 'Severity:1'}, 
		{'role': 'system', 'content': 'The patient has pain and timing explains when the pain worsens (action or none). '}, {'role': 'user', 'content': 'When does your knee pain worsen?'}, {'role': 'assistant', 'content': 'Timing:1'}, 
		{'role': 'system', 'content': 'The patient has pain and timing explains when the pain worsens (action or none). '}, {'role': 'user', 'content': 'How is the timing of your abdominal pain?'}, {'role': 'assistant', 'content': 'Timing:1'}, 
		{'role': 'system', 'content': 'The patient has pain and timing explains when the pain worsens (action or none). '}, {'role': 'user', 'content': 'When does you hurt the most?'}, {'role': 'assistant', 'content': 'Timing:1'}, 
		{'role': 'system', 'content': 'The patient has a chief complaint. This is your primary reason for the consultation. '}, {'role': 'user', 'content': 'What is the purpose of your visit?'}, {'role': 'assistant', 'content': 'Chief Complaint:1'}, 
		{'role': 'system', 'content': 'The patient has concerns regarding the chief complaint. '}, {'role': 'user', 'content': 'Do you have any concerns about the problem?'}, {'role': 'assistant', 'content': 'Concerns Regarding Problem:1'}, 
		{'role': 'system', 'content': 'The patient has history of present illness. '}, {'role': 'user', 'content': 'How long have you experienced your knee pain?'}, {'role': 'assistant', 'content': 'History Of Present Illness:1'}, 
		{'role': 'system', 'content': 'The patient has history of present illness. '}, {'role': 'user', 'content': 'What the history of your illness?'}, {'role': 'assistant', 'content': 'History Of Present Illness:1'}, 
		{'role': 'system', 'content': 'The patient has history of present illness. '}, {'role': 'user', 'content': 'How long have you experienced this pain?'}, {'role': 'assistant', 'content': 'History Of Present Illness:1'}, 
		{'role': 'system', 'content': 'The patient has a stakeholder. '}, {'role': 'user', 'content': 'Who is your stakeholder?'}, {'role': 'assistant', 'content': 'Stakeholder:1'}, 
		{'role': 'system', 'content': "The patient's stakeholder has interest in the issue."}, {'role': 'user', 'content': "What is your stakeholder's interest in issue?"}, {'role': 'assistant', 'content': "Stakeholder's Interest In Issue:1"}, 
		{'role': 'system', 'content': "The patient's stakeholder has a role. "}, {'role': 'user', 'content': "What is your stakeholder's role?"}, {'role': 'assistant', 'content': "Stakeholder's Role:1"}, 
		{'role': 'system', 'content': "The patient's stakeholder has a level of influence. "}, {'role': 'user', 'content': "What is your stakeholder's level of influence?"}, {'role': 'assistant', 'content': "Stakeholder's Level Of Influence:1"}, 
		{'role': 'system', 'content': 'The patient has pertinent beliefs. '}, {'role': 'user', 'content': 'What are you pertinent beliefs?'}, {'role': 'assistant', 'content': 'Pertinent Beliefs:1'}, 
		{'role': 'system', 'content': 'The patient has a disease and it has an impact on your family. '}, {'role': 'user', 'content': 'What is the impact your disease has on your family?'}, {'role': 'assistant', 'content': 'Impact On Family:1'}, 
		{'role': 'system', 'content': 'The patient has facilitating community factors. '}, {'role': 'user', 'content': 'What are your facilitating community factors?'}, {'role': 'assistant', 'content': 'Facilitating:1'}, 
		{'role': 'system', 'content': 'The patient has hindering community factors. '}, {'role': 'user', 'content': 'What are your hindering community factors?'}, {'role': 'assistant', 'content': 'Hindering:1'}, 
		{'role': 'system', 'content': 'The patient has burdens from their illness. '}, {'role': 'user', 'content': 'How does your illness burden you?'}, {'role': 'assistant', 'content': 'Burden Of Illness:1'}, 
		{'role': 'system', 'content': 'The patient has pertinent legislations or policies that affect you. '}, {'role': 'user', 'content': 'What are any pertinent legislations/policies that affect you?'}, {'role': 'assistant', 'content': 'Pertinent Legislation Or Policies:1'}, 
		{'role': 'system', 'content': 'You are a patient that was breastfed until an age. '}, {'role': 'user', 'content': 'Until what age were you breastfed?'}, {'role': 'assistant', 'content': 'Breastfed Till:1'}, 
		{'role': 'system', 'content': 'You are a patient that was given formula as a baby. '}, {'role': 'user', 'content': 'Were you given formula as a baby?'}, {'role': 'assistant', 'content': 'Formula:1'}, 
		{'role': 'system', 'content': 'You are a patient that was weaned at an age. '}, {'role': 'user', 'content': 'How old were you when you were weaned?'}, {'role': 'assistant', 'content': 'Weaning Age:1'}, 
		{'role': 'system', 'content': 'The patient has a current diet. '}, {'role': 'user', 'content': 'What is your current diet?'}, {'role': 'assistant', 'content': 'Current Diet:1'}, 
		{'role': 'system', 'content': 'The patient has food allergies. '}, {'role': 'user', 'content': 'Do you have food allergies?'}, {'role': 'assistant', 'content': 'Food Allergy:1'}, 
		{'role': 'system', 'content': 'The patient was born at a specific term from your mother (early, full, late, post). '}, {'role': 'user', 'content': 'When your mother was pregnant with you, what was the term of her pregnancy?'}, {'role': 'assistant', 'content': 'Term:1'}, 
		{'role': 'system', 'content': 'The patient was born using a delivery method (vaginal delivery, assisted vaginal delivery, C-section, vaginal birth after cesarean). '}, {'role': 'user', 'content': 'How were you delivered as a baby?'}, {'role': 'assistant', 'content': 'Delivered Via:1'}, 
		{'role': 'system', 'content': "The patient's mother was an age when she gave birth to you. "}, {'role': 'user', 'content': 'How old was your mother when she gave birth to you?'}, {'role': 'assistant', 'content': 'To A (Age):1'}, 
		{'role': 'system', 'content': "The patient's mother has been pregnant a number of times. "}, {'role': 'user', 'content': "What is your mother's gravidity?"}, {'role': 'assistant', 'content': 'G:1'}, 
		{'role': 'system', 'content': "The patient's mother has carried a number of pregnancies to at least 20 weeks. "}, {'role': 'user', 'content': 'How many pregnancies has your mother carried to at least 20 weeks?'}, {'role': 'assistant', 'content': 'P:1'}, 
		{'role': 'system', 'content': "The patient's mother has carried a number of pregnancies to at least 20 weeks. "}, {'role': 'user', 'content': "What is your mother's parity?"}, {'role': 'assistant', 'content': 'P:1'}, 
		{'role': 'system', 'content': 'The patient has a birthweight. '}, {'role': 'user', 'content': 'How much did you weigh as a baby?'}, {'role': 'assistant', 'content': 'BW:1'}, 
		{'role': 'system', 'content': 'The patient has a doctor that attended your mother giving birth to you. '}, {'role': 'user', 'content': 'Who attended your mother during her child birth with you?'}, {'role': 'assistant', 'content': 'Attended By First Name:1'}, 
		{'role': 'system', 'content': "The patient's mother's perinatal cervix was at a length during child birth. "}, {'role': 'user', 'content': "What was your mother's perinatal cervix length?"}, {'role': 'assistant', 'content': 'Perinatal CX:1'}, 
		{'role': 'system', 'content': 'The patient has gross motor developmental milestones. '}, {'role': 'user', 'content': 'What are your gross motor milestones?'}, {'role': 'assistant', 'content': 'Gross Motor:1'}, 
		{'role': 'system', 'content': 'The patient has adaptive-fine motor developmental milestones. '}, {'role': 'user', 'content': 'What are your adaptive-fine motor developmental milestones?'}, {'role': 'assistant', 'content': 'Adaptive-Fine Motor:1'}, 
		{'role': 'system', 'content': 'The patient has speech developmental milestones. '}, {'role': 'user', 'content': 'What are your speech developmental milestones?'}, {'role': 'assistant', 'content': 'Speech:1'}, 
		{'role': 'system', 'content': 'The patient has personal and social developmental milestones. This includes your career, drinking history, and smoking history. '}, {'role': 'user', 'content': 'What are your personal and social developmental milestones?'}, {'role': 'assistant', 'content': 'Personal And Social:1'}, 
		{'role': 'system', 'content': 'The patient has fever. '}, {'role': 'user', 'content': 'Do you have fever?'}, {'role': 'assistant', 'content': 'Fever:1'}, 
		{'role': 'system', 'content': 'The patient has weight gain. '}, {'role': 'user', 'content': 'Do you have weight gain?'}, {'role': 'assistant', 'content': 'Weight Gain:1'}, 
		{'role': 'system', 'content': 'The patient has weight loss. '}, {'role': 'user', 'content': 'Do you have weight loss?'}, {'role': 'assistant', 'content': 'Weight Loss:1'}, 
		{'role': 'system', 'content': 'The patient has weakness. '}, {'role': 'user', 'content': 'Do you have weakness?'}, {'role': 'assistant', 'content': 'Weakness:1'}, 
		{'role': 'system', 'content': 'The patient has fatigue. '}, {'role': 'user', 'content': 'Do you have fatigue?'}, {'role': 'assistant', 'content': 'Fatigue:1'}, 
		{'role': 'system', 'content': 'The patient has other general symptoms. '}, {'role': 'user', 'content': 'Do you have other general symptoms?'}, {'role': 'assistant', 'content': 'Other General Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has rashes. '}, {'role': 'user', 'content': 'Do you have rashes?'}, {'role': 'assistant', 'content': 'Rashes:1'}, 
		{'role': 'system', 'content': 'The patient has lumps. '}, {'role': 'user', 'content': 'Do you have lumps?'}, {'role': 'assistant', 'content': 'Lumps:1'}, 
		{'role': 'system', 'content': 'The patient has sores. '}, {'role': 'user', 'content': 'Do you have sores?'}, {'role': 'assistant', 'content': 'Sores:1'}, 
		{'role': 'system', 'content': 'The patient has itching. '}, {'role': 'user', 'content': 'Do you have itching?'}, {'role': 'assistant', 'content': 'Itching:1'}, 
		{'role': 'system', 'content': 'The patient has muscle pains. '}, {'role': 'user', 'content': 'Do you have muscle pains?'}, {'role': 'assistant', 'content': 'Muscle Pains:1'}, 
		{'role': 'system', 'content': 'The patient has joint pains. '}, {'role': 'user', 'content': 'Do you have joint pains?'}, {'role': 'assistant', 'content': 'Joint Pains:1'}, 
		{'role': 'system', 'content': 'The patient has changes in skin color. '}, {'role': 'user', 'content': 'Do you have changes in skin color?'}, {'role': 'assistant', 'content': 'Changes in Skin Color:1'}, 
		{'role': 'system', 'content': 'The patient has joint swelling. '}, {'role': 'user', 'content': 'Do you have joint swelling?'}, {'role': 'assistant', 'content': 'Joint Swelling:1'}, 
		{'role': 'system', 'content': 'The patient has changes in hair/nails. '}, {'role': 'user', 'content': 'Do you have changes in hair/nails?'}, {'role': 'assistant', 'content': 'Changes in Hair/Nails:1'}, 
		{'role': 'system', 'content': 'The patient has changes in hair/nails. '}, {'role': 'user', 'content': 'Do you have changes in hair?'}, {'role': 'assistant', 'content': 'Changes in Hair/Nails:1'}, 
		{'role': 'system', 'content': 'The patient has changes in hair/nails. '}, {'role': 'user', 'content': 'Do you have changes in nails?'}, {'role': 'assistant', 'content': 'Changes in Hair/Nails:1'}, 
		{'role': 'system', 'content': 'The patient has gout. '}, {'role': 'user', 'content': 'Do you have gout?'}, {'role': 'assistant', 'content': 'Gout:1'}, 
		{'role': 'system', 'content': 'The patient has other musculoskeletal or dermatologic symptoms. '}, {'role': 'user', 'content': 'Do you have other musculoskeletal or dermatologic symptoms?'}, {'role': 'assistant', 'content': 'Other Musculoskeletal or Dermatologic Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has other musculoskeletal or dermatologic symptoms. '}, {'role': 'user', 'content': 'Do you have any other musculoskeletal symptoms?'}, {'role': 'assistant', 'content': 'Other Musculoskeletal or Dermatologic Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has other musculoskeletal or dermatologic symptoms. '}, {'role': 'user', 'content': 'Do you have any other dermatologic symptoms?'}, {'role': 'assistant', 'content': 'Other Musculoskeletal or Dermatologic Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has other musculoskeletal or dermatologic symptoms. '}, {'role': 'user', 'content': 'Do you have any other joint symptoms?'}, {'role': 'assistant', 'content': 'Other Musculoskeletal or Dermatologic Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has other musculoskeletal or dermatologic symptoms. '}, {'role': 'user', 'content': 'Do you have any other skin symptoms?'}, {'role': 'assistant', 'content': 'Other Musculoskeletal or Dermatologic Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has other musculoskeletal or dermatologic symptoms. '}, {'role': 'user', 'content': 'Do you have any other muscle symptoms?'}, {'role': 'assistant', 'content': 'Other Musculoskeletal or Dermatologic Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has headache. '}, {'role': 'user', 'content': 'Do you have headache?'}, {'role': 'assistant', 'content': 'Headache:1'}, 
		{'role': 'system', 'content': 'The patient has dizziness. '}, {'role': 'user', 'content': 'Do you have dizziness?'}, {'role': 'assistant', 'content': 'Dizziness:1'}, 
		{'role': 'system', 'content': 'The patient has blurring of vision. '}, {'role': 'user', 'content': 'Do you have blurring of vision?'}, {'role': 'assistant', 'content': 'Blurring of Vision:1'}, 
		{'role': 'system', 'content': 'The patient has tinnitus. '}, {'role': 'user', 'content': 'Do you have tinnitus?'}, {'role': 'assistant', 'content': 'Tinnitus:1'}, 
		{'role': 'system', 'content': 'The patient has deafness. '}, {'role': 'user', 'content': 'Do you have deafness?'}, {'role': 'assistant', 'content': 'Deafness:1'}, 
		{'role': 'system', 'content': 'The patient has nosebleeds. '}, {'role': 'user', 'content': 'Do you have nosebleeds?'}, {'role': 'assistant', 'content': 'Nosebleeds:1'}, 
		{'role': 'system', 'content': 'The patient has frequent colds. '}, {'role': 'user', 'content': 'Do you have frequent colds?'}, {'role': 'assistant', 'content': 'Frequent Colds:1'}, 
		{'role': 'system', 'content': 'The patient has hoarseness. '}, {'role': 'user', 'content': 'Do you have hoarseness?'}, {'role': 'assistant', 'content': 'Hoarseness:1'}, 
		{'role': 'system', 'content': 'The patient has dry mouth. '}, {'role': 'user', 'content': 'Do you have dry mouth?'}, {'role': 'assistant', 'content': 'Dry Mouth:1'}, 
		{'role': 'system', 'content': 'The patient has gum bleeding. '}, {'role': 'user', 'content': 'Do you have gum bleeding?'}, {'role': 'assistant', 'content': 'Gum Bleeding:1'}, 
		{'role': 'system', 'content': 'The patient has enlarged lymph nodes. '}, {'role': 'user', 'content': 'Do you have enlarged lymph nodes?'}, {'role': 'assistant', 'content': 'Enlarged Lymph Nodes:1'}, 
		{'role': 'system', 'content': 'The patient has other HEENT symptoms. '}, {'role': 'user', 'content': 'Do you have other HEENT symptoms?'}, {'role': 'assistant', 'content': 'Other HEENT Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has shortness of breath. '}, {'role': 'user', 'content': 'Do you have dyspnea?'}, {'role': 'assistant', 'content': 'Dyspnea:1'}, 
		{'role': 'system', 'content': 'The patient has shortness of breath. '}, {'role': 'user', 'content': 'Do you have shortness of breath?'}, {'role': 'assistant', 'content': 'Dyspnea:1'}, 
		{'role': 'system', 'content': 'You are a patient that coughs up blood. '}, {'role': 'user', 'content': 'Do you have hemoptysis?'}, {'role': 'assistant', 'content': 'Hemoptysis:1'}, 
		{'role': 'system', 'content': 'You are a patient that coughs up blood. '}, {'role': 'user', 'content': 'Are you coughing up blood?'}, {'role': 'assistant', 'content': 'Hemoptysis:1'}, 
		{'role': 'system', 'content': 'The patient has cough. '}, {'role': 'user', 'content': 'Do you have cough?'}, {'role': 'assistant', 'content': 'Cough:1'}, 
		{'role': 'system', 'content': 'The patient has wheezing. '}, {'role': 'user', 'content': 'Do you have wheezing?'}, {'role': 'assistant', 'content': 'Wheezing:1'}, 
		{'role': 'system', 'content': 'The patient has other respiratory symptoms. '}, {'role': 'user', 'content': 'Do you have other respiratory symptoms?'}, {'role': 'assistant', 'content': 'Other Respiratory Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has palpitations. '}, {'role': 'user', 'content': 'Do you have palpitations?'}, {'role': 'assistant', 'content': 'Palpitations:1'}, 
		{'role': 'system', 'content': 'The patient has chest pains. '}, {'role': 'user', 'content': 'Do you have chest pains?'}, {'role': 'assistant', 'content': 'Chest Pains:1'}, 
		{'role': 'system', 'content': 'The patient faints. '}, {'role': 'user', 'content': 'Do you have syncope?'}, {'role': 'assistant', 'content': 'Syncope:1'}, 
		{'role': 'system', 'content': 'The patient faints. '}, {'role': 'user', 'content': 'Do you faint?'}, {'role': 'assistant', 'content': 'Syncope:1'}, 
		{'role': 'system', 'content': 'The patient has shortness of breath when lying on your back. '}, {'role': 'user', 'content': 'Do you have orthopnea?'}, {'role': 'assistant', 'content': 'Orthopnea:1'}, 
		{'role': 'system', 'content': 'The patient has shortness of breath when lying on your back. '}, {'role': 'user', 'content': 'Do you have shortness of breath when you lie on your back?'}, {'role': 'assistant', 'content': 'Orthopnea:1'}, 
		{'role': 'system', 'content': 'The patient has other cardiovascular symptoms. '}, {'role': 'user', 'content': 'Do you have other cardiovascular symptoms?'}, {'role': 'assistant', 'content': 'Other Cardiovascular Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has nausea. '}, {'role': 'user', 'content': 'Do you have nausea?'}, {'role': 'assistant', 'content': 'Nausea:1'}, 
		{'role': 'system', 'content': 'The patient has vomiting. '}, {'role': 'user', 'content': 'Do you have vomiting?'}, {'role': 'assistant', 'content': 'Vomiting:1'}, 
		{'role': 'system', 'content': 'The patient has difficulty swallowing. '}, {'role': 'user', 'content': 'Do you have dysphagia?'}, {'role': 'assistant', 'content': 'Dysphagia:1'}, 
		{'role': 'system', 'content': 'The patient has difficulty swallowing. '}, {'role': 'user', 'content': 'Do you have difficulty swallowing?'}, {'role': 'assistant', 'content': 'Dysphagia:1'}, 
		{'role': 'system', 'content': 'The patient has heartburn. '}, {'role': 'user', 'content': 'Do you have heartburn?'}, {'role': 'assistant', 'content': 'Heartburn:1'}, 
		{'role': 'system', 'content': 'The patient has change in bowel habits. '}, {'role': 'user', 'content': 'Do you have change in bowel habits?'}, {'role': 'assistant', 'content': 'Change in Bowel Habits:1'}, 
		{'role': 'system', 'content': 'The patient has rectal bleeding. '}, {'role': 'user', 'content': 'Do you have rectal bleeding?'}, {'role': 'assistant', 'content': 'Rectal Bleeding:1'}, 
		{'role': 'system', 'content': 'The patient has jaundice. '}, {'role': 'user', 'content': 'Do you have jaundice?'}, {'role': 'assistant', 'content': 'Jaundice:1'}, 
		{'role': 'system', 'content': 'The patient has other gastrointestinal symptoms. '}, {'role': 'user', 'content': 'Do you have other gastrointestinal symptoms?'}, {'role': 'assistant', 'content': 'Other Gastrointestinal Symptoms:1'}, 
		{'role': 'system', 'content': 'You are a patient that pees a lot during night. '}, {'role': 'user', 'content': 'Do you have nocturia?'}, {'role': 'assistant', 'content': 'Nocturia:1'}, 
		{'role': 'system', 'content': 'You are a patient that pees a lot during night. '}, {'role': 'user', 'content': 'Do you urinate often during the night?'}, {'role': 'assistant', 'content': 'Nocturia:1'}, 
		{'role': 'system', 'content': 'You are a patient that has pain when you pee. '}, {'role': 'user', 'content': 'Do you have dysuria?'}, {'role': 'assistant', 'content': 'Dysuria:1'}, 
		{'role': 'system', 'content': 'You are a patient that has pain when you pee. '}, {'role': 'user', 'content': 'Does it hurt when you urinate?'}, {'role': 'assistant', 'content': 'Dysuria:1'}, 
		{'role': 'system', 'content': 'You are a patient that pees more often than average. '}, {'role': 'user', 'content': 'Do you have urinary frequency?'}, {'role': 'assistant', 'content': 'Urinary Frequency:1'}, 
		{'role': 'system', 'content': 'You are a patient that pees more often than average. '}, {'role': 'user', 'content': 'Do you urinate more often than average?'}, {'role': 'assistant', 'content': 'Urinary Frequency:1'}, 
		{'role': 'system', 'content': 'The patient has blood in your urine. '}, {'role': 'user', 'content': 'Do you have hematuria?'}, {'role': 'assistant', 'content': 'Hematuria:1'}, 
		{'role': 'system', 'content': 'The patient has blood in your urine. '}, {'role': 'user', 'content': 'Do you have blood in your urine?'}, {'role': 'assistant', 'content': 'Hematuria:1'}, 
		{'role': 'system', 'content': 'The patient has other genitourinary symptoms. '}, {'role': 'user', 'content': 'Do you have other genitourinary symptoms?'}, {'role': 'assistant', 'content': 'Other Genitourinary Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has excessive sweating. '}, {'role': 'user', 'content': 'Do you have excessive sweating?'}, {'role': 'assistant', 'content': 'Excessive Sweating:1'}, 
		{'role': 'system', 'content': 'The patient has heat intolerance. '}, {'role': 'user', 'content': 'Do you have heat intolerance?'}, {'role': 'assistant', 'content': 'Heat Intolerance:1'}, 
		{'role': 'system', 'content': 'You are a patient that pees more than the average amount. '}, {'role': 'user', 'content': 'Do you have polyuria?'}, {'role': 'assistant', 'content': 'Polyuria:1'}, 
		{'role': 'system', 'content': 'You are a patient that pees more than the average amount. '}, {'role': 'user', 'content': 'Do you have excessive urine production?'}, {'role': 'assistant', 'content': 'Polyuria:1'}, 
		{'role': 'system', 'content': 'You are a patient that pees more than the average amount. '}, {'role': 'user', 'content': 'Do you pee more than the average amount ?'}, {'role': 'assistant', 'content': 'Polyuria:1'}, 
		{'role': 'system', 'content': 'The patient has excessive thirst. '}, {'role': 'user', 'content': 'Do you have excessive thirst?'}, {'role': 'assistant', 'content': 'Excessive Thirst:1'}, 
		{'role': 'system', 'content': 'The patient has cold intolerance. '}, {'role': 'user', 'content': 'Do you have cold intolerance?'}, {'role': 'assistant', 'content': 'Cold Intolerance:1'}, 
		{'role': 'system', 'content': 'The patient has other endocrine symptoms. '}, {'role': 'user', 'content': 'Do you have other endocrine symptoms?'}, {'role': 'assistant', 'content': 'Other Endocrine Symptoms:1'}, 
		{'role': 'system', 'content': 'The patient has history of tuberculosis. '}, {'role': 'user', 'content': "Do you have Primary Koch's infection?"}, {'role': 'assistant', 'content': 'History of Tuberculosis:1'}, 
		{'role': 'system', 'content': 'The patient has history of tuberculosis. '}, {'role': 'user', 'content': 'Do you have history of tuberculosis?'}, {'role': 'assistant', 'content': 'History of Tuberculosis:1'}, 
		{'role': 'system', 'content': 'The patient has history of asthma. '}, {'role': 'user', 'content': 'Do you have history of asthma?'}, {'role': 'assistant', 'content': 'History of Asthma:1'}, 
		{'role': 'system', 'content': 'The patient has history of diabetes. '}, {'role': 'user', 'content': 'Do you have history of diabetes?'}, {'role': 'assistant', 'content': 'History of Diabetes:1'}, 
		{'role': 'system', 'content': 'The patient has history of hypertension. '}, {'role': 'user', 'content': 'Do you have history of hypertension?'}, {'role': 'assistant', 'content': 'History of Hypertension:1'}, 
		{'role': 'system', 'content': 'The patient has history of psychiatric consult. '}, {'role': 'user', 'content': 'Do you have history of psychiatric consult?'}, {'role': 'assistant', 'content': 'History of Psychiatric Consult:1'}, 
		{'role': 'system', 'content': 'The patient has history of cancer. '}, {'role': 'user', 'content': 'Do you have history of cancer?'}, {'role': 'assistant', 'content': 'History of Cancer:1'}, 
		{'role': 'system', 'content': 'The patient has prior surgeries/hospitalizations. '}, {'role': 'user', 'content': 'Do you have prior surgeries/hospitalizations?'}, {'role': 'assistant', 'content': 'Prior Surgeries/Hospitalizations:1'}, 
		{'role': 'system', 'content': 'The patient has prior surgeries/hospitalizations. '}, {'role': 'user', 'content': 'Do you have prior hospitalizations?'}, {'role': 'assistant', 'content': 'Prior Surgeries/Hospitalizations:1'}, 
		{'role': 'system', 'content': 'The patient has prior surgeries/hospitalizations. '}, {'role': 'user', 'content': 'Do you have prior surgeries?'}, {'role': 'assistant', 'content': 'Prior Surgeries/Hospitalizations:1'}, 
		{'role': 'system', 'content': 'The patient has history of allergies. '}, {'role': 'user', 'content': 'Do you have history of allergies?'}, {'role': 'assistant', 'content': 'History of Allergies:1'}, 
		{'role': 'system', 'content': 'The patient has cancer site in history. '}, {'role': 'user', 'content': 'Do you have cancer site in history?'}, {'role': 'assistant', 'content': 'Cancer Site in History:1'}, 
		{'role': 'system', 'content': 'The patient has prior surgeries or hospitalization dates. '}, {'role': 'user', 'content': 'When were your prior surgeries or hospitalizations?'}, {'role': 'assistant', 'content': 'Prior Surgeries Or Hospitalization Dates:1'}, 
		{'role': 'system', 'content': 'The patient has prior surgeries or hospitalization reasons. '}, {'role': 'user', 'content': 'What was the reason for your prior surgeries or hospitalizations?'}, {'role': 'assistant', 'content': 'Prior Surgeries Or Hospitalization Reasons:1'}, 
		{'role': 'system', 'content': 'The patient has prior surgeries or hospitalization dates. '}, {'role': 'user', 'content': 'When were your prior surgeries?'}, {'role': 'assistant', 'content': 'Prior Surgeries Or Hospitalization Dates:1'}, 
		{'role': 'system', 'content': 'The patient has prior surgeries or hospitalization reasons. '}, {'role': 'user', 'content': 'What was the reason for your prior surgeries?'}, {'role': 'assistant', 'content': 'Prior Surgeries Or Hospitalization Reasons:1'}, 
		{'role': 'system', 'content': 'The patient has prior surgeries or hospitalization dates. '}, {'role': 'user', 'content': 'When were your prior hospitalizations?'}, {'role': 'assistant', 'content': 'Prior Surgeries Or Hospitalization Dates:1'}, 
		{'role': 'system', 'content': 'The patient has prior surgeries or hospitalization reasons. '}, {'role': 'user', 'content': 'What was the reason for your prior hosptializations?'}, {'role': 'assistant', 'content': 'Prior Surgeries Or Hospitalization Reasons:1'}, 
		{'role': 'system', 'content': 'The patient has allergies in history. '}, {'role': 'user', 'content': 'Do you have allergies in history?'}, {'role': 'assistant', 'content': 'Allergies in History:1'}, 
		{'role': 'system', 'content': 'The patient has other past medical history. '}, {'role': 'user', 'content': 'Do you have other past medical history?'}, {'role': 'assistant', 'content': 'Other Past Medical History:1'}, 
		{'role': 'system', 'content': 'The patient has family history of tubercolosis. '}, {'role': 'user', 'content': 'Do you have family history of tubercolosis?'}, {'role': 'assistant', 'content': 'Family History of Tuberculosis:1'}, 
		{'role': 'system', 'content': 'The patient has family history of asthma. '}, {'role': 'user', 'content': 'Do you have family history of asthma?'}, {'role': 'assistant', 'content': 'Family History of Asthma:1'}, 
		{'role': 'system', 'content': 'The patient has family history of psychiatric consult. '}, {'role': 'user', 'content': 'Do you have family history of psychiatric consult?'}, {'role': 'assistant', 'content': 'Family History of Psychiatric Consult:1'}, 
		{'role': 'system', 'content': 'The patient has family history of diabetes. '}, {'role': 'user', 'content': 'Do you have family history of diabetes?'}, {'role': 'assistant', 'content': 'Family History of Diabetes:1'}, 
		{'role': 'system', 'content': 'The patient has family history of cardiovascular disease. '}, {'role': 'user', 'content': 'Do you have family history of cardiovascular disease?'}, {'role': 'assistant', 'content': 'Family History of Cardiovascular Disease:1'}, 
		{'role': 'system', 'content': 'The patient has family history of cancer. '}, {'role': 'user', 'content': 'Do you have family history of cancer?'}, {'role': 'assistant', 'content': 'Family History of Cancer:1'}, 
		{'role': 'system', 'content': 'The patient has family history of allergies. '}, {'role': 'user', 'content': 'Do you have family history of allergies?'}, {'role': 'assistant', 'content': 'Family History of Allergies:1'}, 
		{'role': 'system', 'content': 'The patient has cancer site in family history. '}, {'role': 'user', 'content': 'Do you have cancer site in family history?'}, {'role': 'assistant', 'content': 'Cancer Site in Family History:1'}, 
		{'role': 'system', 'content': 'The patient has relationship to cancer patient. '}, {'role': 'user', 'content': 'Who had cancer in your family history?'}, {'role': 'assistant', 'content': 'Relationship To Cancer Patient:1'}, 
		{'role': 'system', 'content': 'The patient has allergies in family history. '}, {'role': 'user', 'content': 'Do you have allergies in family history?'}, {'role': 'assistant', 'content': 'Allergies In Family History:1'}, 
		{'role': 'system', 'content': 'The patient has other family history. '}, {'role': 'user', 'content': 'Do you have other family history?'}, {'role': 'assistant', 'content': 'Other Family History:1'}, 
		{'role': 'system', 'content': 'The patient has genogram. '}, {'role': 'user', 'content': 'Can you describe your genogram?'}, {'role': 'assistant', 'content': 'Genogram (Describe Through Text):1'}, 
		{'role': 'system', 'content': 'The patient has social and environmental history. '}, {'role': 'user', 'content': 'Do you have social and environmental history?'}, {'role': 'assistant', 'content': 'Social And Environmental History:1'}, 
		{'role': 'system', 'content': 'The patient has the start date of their last menstrual period. '}, {'role': 'user', 'content': 'When did your last menstrual period start?'}, {'role': 'assistant', 'content': 'Last Menstrual Period (YYYY-MM-DD):1'}, 
		{'role': 'system', 'content': 'The patient has the start date of the menstrual period before their last. '}, {'role': 'user', 'content': 'When did your previous menstrual period start?'}, {'role': 'assistant', 'content': 'Previous Menstrual Period (YYYY-MM-DD):1'}, 
		{'role': 'system', 'content': 'The patient has duration of menstrual period. '}, {'role': 'user', 'content': 'How long are your menstrual periods?'}, {'role': 'assistant', 'content': 'Duration Of Menses:1'}, 
		{'role': 'system', 'content': 'The patient has interval of your menstrual cycles. '}, {'role': 'user', 'content': 'How long are your menstrual cycles?'}, {'role': 'assistant', 'content': 'Interval Of Menses:1'}, 
		{'role': 'system', 'content': 'The patient has volume of menstrual period. '}, {'role': 'user', 'content': 'How much do you bleed during your menstrual period?'}, {'role': 'assistant', 'content': 'Volume Of Menses:1'}, 
		{'role': 'system', 'content': 'The patient has the age they had their first period. '}, {'role': 'user', 'content': 'When did you experience menarche?'}, {'role': 'assistant', 'content': 'Menarche:1'}, 
		{'role': 'system', 'content': 'The patient has the age they had their first period. '}, {'role': 'user', 'content': 'When did you had your first period?'}, {'role': 'assistant', 'content': 'Menarche:1'}, 
		{'role': 'system', 'content': 'The patient has the age they had their first sex. '}, {'role': 'user', 'content': 'When did you experience coitarche?'}, {'role': 'assistant', 'content': 'Coitarche:1'}, 
		{'role': 'system', 'content': 'The patient has the age they had their first sex. '}, {'role': 'user', 'content': 'When did you had your first sexual intercourse?'}, {'role': 'assistant', 'content': 'Coitarche:1'}, 
		{'role': 'system', 'content': 'The patient has complete DPT/Polio immunization. '}, {'role': 'user', 'content': 'Do you have complete DPT/Polio immunization?'}, {'role': 'assistant', 'content': 'DPT/Polio Immunization:1'}, 
		{'role': 'system', 'content': 'The patient has complete HIB immunization. '}, {'role': 'user', 'content': 'Do you have complete HIB immunization?'}, {'role': 'assistant', 'content': 'HIB Immunization:1'}, 
		{'role': 'system', 'content': 'The patient has complete Hepatitis B immunization. '}, {'role': 'user', 'content': 'Do you have complete Hepatitis B immunization?'}, {'role': 'assistant', 'content': 'Hepatitis B Immunization:1'}, 
		{'role': 'system', 'content': 'The patient has complete MMR immunization. '}, {'role': 'user', 'content': 'Do you have complete MMR immunization?'}, {'role': 'assistant', 'content': 'MMR Immunization:1'}, 
		{'role': 'system', 'content': 'The patient has complete Measles immunization. '}, {'role': 'user', 'content': 'Do you have complete Measles immunization?'}, {'role': 'assistant', 'content': 'Measles Immunization:1'}, 
		{'role': 'system', 'content': 'The patient has complete Varicella immunization. '}, {'role': 'user', 'content': 'Do you have complete Varicella immunization?'}, {'role': 'assistant', 'content': 'Varicella Immunization:1'}, 
		{'role': 'system', 'content': 'The patient has complete Pneumococcal immunization. '}, {'role': 'user', 'content': 'Do you have complete Pneumococcal immunization?'}, {'role': 'assistant', 'content': 'Pneumococcal Immunization:1'}, 
		{'role': 'system', 'content': 'The patient has complete Influenza immunization. '}, {'role': 'user', 'content': 'Do you have complete Influenza immunization?'}, {'role': 'assistant', 'content': 'Influenza Immunization:1'}, 
		{'role': 'system', 'content': 'The patient has complete Hepatitis A immunization. '}, {'role': 'user', 'content': 'Do you have complete Hepatitis A immunization?'}, {'role': 'assistant', 'content': 'Hepatitis A Immunization:1'}, 
		{'role': 'system', 'content': 'The patient has DPT/Polio doses. '}, {'role': 'user', 'content': 'Do you have DPT/Polio doses?'}, {'role': 'assistant', 'content': 'DPT/Polio Doses:1'}, 
		{'role': 'system', 'content': 'The patient has HIB doses. '}, {'role': 'user', 'content': 'Do you have HIB doses?'}, {'role': 'assistant', 'content': 'HIB Doses:1'}, 
		{'role': 'system', 'content': 'The patient has Hepatitis B doses. '}, {'role': 'user', 'content': 'Do you have Hepatitis B doses?'}, {'role': 'assistant', 'content': 'Hepatitis B Doses:1'}, 
		{'role': 'system', 'content': 'The patient has MMR doses. '}, {'role': 'user', 'content': 'Do you have MMR doses?'}, {'role': 'assistant', 'content': 'MMR Doses:1'}, 
		{'role': 'system', 'content': 'The patient has Measles doses. '}, {'role': 'user', 'content': 'Do you have Measles doses?'}, {'role': 'assistant', 'content': 'Measles Doses:1'}, 
		{'role': 'system', 'content': 'The patient has Varicella doses. '}, {'role': 'user', 'content': 'Do you have Varicella doses?'}, {'role': 'assistant', 'content': 'Varicella Doses:1'}, 
		{'role': 'system', 'content': 'The patient has Pneumococcal doses. '}, {'role': 'user', 'content': 'Do you have Pneumococcal doses?'}, {'role': 'assistant', 'content': 'Pneumococcal Doses:1'}, 
		{'role': 'system', 'content': 'The patient has Influenza doses. '}, {'role': 'user', 'content': 'Do you have Influenza doses?'}, {'role': 'assistant', 'content': 'Influenza Doses:1'}, 
		{'role': 'system', 'content': 'The patient has Hepatitis A doses. '}, {'role': 'user', 'content': 'Do you have Hepatitis A doses?'}, {'role': 'assistant', 'content': 'Hepatitis A Doses:1'}, 
		{'role': 'system', 'content': 'The patient has other immunizations. '}, {'role': 'user', 'content': 'Do you have other immunizations?'}, {'role': 'assistant', 'content': 'Other Immunizations:1'}, 
		{'role': 'system', 'content': 'The patient has other medications. '}, {'role': 'user', 'content': 'Do you have other medications?'}, {'role': 'assistant', 'content': 'Medications:1'}, 
		{'role': 'system', 'content': 'The patient has additional details regarding history. '}, {'role': 'user', 'content': 'Do you have additional details regarding history?'}, {'role': 'assistant', 'content': 'Additional Details Regarding History:1'}, 
		{'role': 'system', 'content': 'The patient has additional details regarding context including ethical considerations. '}, {'role': 'user', 'content': 'Do you have additional details regarding context including ethical considerations?'}, {'role': 'assistant', 'content': 'Additional Details Regarding Context Including Ethical Considerations:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': "I'm sorry about your condition. Are you intolerant to heat or cold?"}, {'role': 'assistant', 'content': 'Support:1; Heat Intolerance:1; Cold Intolerance:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'The patient has fever. '}, {'role': 'user', 'content': 'It must be very difficult going through all of this. Do you have fever?'}, {'role': 'assistant', 'content': 'Support:1; Fever:1'}, 
		{'role': 'system', 'content': 'The patient has weight gain. '}, {'role': 'user', 'content': 'I understand your situation. Do you have weight gain?'}, {'role': 'assistant', 'content': 'Support:1; Weight Gain:1'}, 
		{'role': 'system', 'content': 'The patient has weight loss. '}, {'role': 'user', 'content': "I'm sorry about your condition. Do you have weight loss?"}, {'role': 'assistant', 'content': 'Support:1; Weight Loss:1'}, 
		{'role': 'system', 'content': 'The patient has weakness. '}, {'role': 'user', 'content': 'It must be very difficult going through all of this. Do you have weakness?'}, {'role': 'assistant', 'content': 'Support:1; Weakness:1'}, 
		{'role': 'system', 'content': 'The patient has fatigue. '}, {'role': 'user', 'content': 'I understand your situation. Do you have fatigue?'}, {'role': 'assistant', 'content': 'Support:1; Fatigue:1'}, 
		{'role': 'system', 'content': 'The patient has other general symptoms. '}, {'role': 'user', 'content': "I'm sorry about your condition. Do you have other general symptoms?"}, {'role': 'assistant', 'content': 'Support:1; Other General Symptoms:1'}, 
		{'role': 'system', 'content': 'You must identify the attribute the med student is asking for and give them a 1 for appropriate and 0.5 for inappropriate.'}, {'role': 'user', 'content': 'Everyone has problems. You just need to get over it. Are you intolerant to heat or cold?'}, {'role': 'assistant', 'content': 'Support:0.5; Heat Intolerance:1; Cold Intolerance:1; Avoid Multiple:0'}, 
		{'role': 'system', 'content': 'The patient has fever. '}, {'role': 'user', 'content': "That's not that big of a deal. Do you have fever?"}, {'role': 'assistant', 'content': 'Support:0.5; Fever:1'}, 
		{'role': 'system', 'content': 'The patient has weight gain. '}, {'role': 'user', 'content': 'Just try to relax okay? Do you have weight gain?'}, {'role': 'assistant', 'content': 'Support:0.5; Weight Gain:1'}, 
		{'role': 'system', 'content': 'The patient has weight loss. '}, {'role': 'user', 'content': 'Everyone has problems. You just need to get over it. Do you have weight loss?'}, {'role': 'assistant', 'content': 'Support:0.5; Weight Loss:1'}, 
		{'role': 'system', 'content': 'The patient has weakness. '}, {'role': 'user', 'content': "That's not that big of a deal. Do you have weakness?"}, {'role': 'assistant', 'content': 'Support:0.5; Weakness:1'}, 
		{'role': 'system', 'content': 'The patient has fatigue. '}, {'role': 'user', 'content': 'Just try to relax okay? Do you have fatigue?'}, {'role': 'assistant', 'content': 'Support:0.5; Fatigue:1'}, 
		{'role': 'system', 'content': 'The patient has other general symptoms. '}, {'role': 'user', 'content': 'Everyone has problems. You just need to get over it. Do you have other general symptoms?'}, {'role': 'assistant', 'content': 'Support:0.5; Other General Symptoms:1'}
	]


func _get_mentor_fields() -> void:
	var mentorfieldscsv = [    
		['Chief Complaint'], 
		['Provocation', 'Quality', 'Region', 'Severity', 'Timing', 'Term', 'Delivered Via', 'To A (Age)', 'G', 'P', 'BW', 'Attended By First Name', 'Attended By Last Name', 'Perinatal CX', 'Fever', 'Weight Gain', 'Weight Loss', 'Weakness', 'Fatigue', 'Rashes', 'Lumps', 'Sores', 'Itching', 'Muscle Pains', 'Joint Pains', 'Changes in Skin Color', 'Joint Swelling', 'Changes in Hair/Nails', 'Gout', 'Headache', 'Dizziness', 'Blurring of Vision', 'Tinnitus', 'Deafness', 'Nosebleeds', 'Frequent Colds', 'Hoarseness', 'Dry Mouth', 'Gum Bleeding', 'Enlarged Lymph Nodes', 'Dyspnea', 'Hemoptysis', 'Cough', 'Wheezing', 'Palpitations', 'Chest Pains', 'Syncope', 'Orthopnea', 'Nausea', 'Vomiting', 'Dysphagia', 'Heartburn', 'Change in Bowel Habits', 'Rectal Bleeding', 'Jaundice', 'Nocturia', 'Dysuria', 'Urinary Frequency', 'Hematuria', 'Excessive Sweating', 'Heat Intolerance', 'Polyuria', 'Excessive Thirst', 'Cold Intolerance', 'History of Tuberculosis', 'History of Asthma', 'History of Diabetes', 'History of Hypertension', 'History of Psychiatric Consult', 'History of Cancer', 'Prior Surgeries/Hospitalizations', 'History of Allergies', 'Cancer Site in History', 'Prior Surgeries Or Hospitalization Dates', 'Prior Surgeries Or Hospitalization Reasons', 'Allergies in History', 'Family History of Tuberculosis', 'Family History of Asthma', 'Family History of Psychiatric Consult', 'Family History of Diabetes', 'Family History of Cardiovascular Disease', 'Family History of Cancer', 'Family History of Allergies', 'Cancer Site in Family History', 'Relationship To Cancer Patient', 'Allergies In Family History', 'Genogram (Describe Through Text)', 'Social And Environmental History', 'Last Menstrual Period (YYYY-MM-DD)', 'Previous Menstrual Period (YYYY-MM-DD)', 'Duration Of Menses', 'Interval Of Menses', 'Volume Of Menses', 'Menarche', 'Coitarche', 'DPT/Polio Immunization', 'HIB Immunization', 'Hepatitis B Immunization', 'MMR Immunization', 'Measles Immunization', 'Varicella Immunization', 'Pneumococcal Immunization', 'Influenza Immunization', 'Hepatitis A Immunization', 'DPT/Polio Doses', 'HIB Doses', 'Hepatitis B Doses', 'MMR Doses', 'Measles Doses', 'Varicella Doses', 'Pneumococcal Doses', 'Influenza Doses', 'Hepatitis A Doses', 'Medications'], 
		['Age', 'Sex', 'Provocation', 'Quality', 'Region', 'Severity', 'Timing', 'History Of Present Illness', 'Breastfed Till', 'Formula', 'Weaning Age', 'Current Diet', 'Food Allergy', 'Gross Motor', 'Adaptive-Fine Motor', 'Speech', 'Fever', 'Weight Gain', 'Weight Loss', 'Weakness', 'Fatigue', 'Other General Symptoms', 'Rashes', 'Lumps', 'Sores', 'Itching', 'Muscle Pains', 'Joint Pains', 'Changes in Skin Color', 'Joint Swelling', 'Changes in Hair/Nails', 'Gout', 'Other Musculoskeletal or Dermatologic Symptoms', 'Headache', 'Dizziness', 'Blurring of Vision', 'Tinnitus', 'Deafness', 'Nosebleeds', 'Frequent Colds', 'Hoarseness', 'Dry Mouth', 'Gum Bleeding', 'Enlarged Lymph Nodes', 'Other HEENT Symptoms', 'Dyspnea', 'Hemoptysis', 'Cough', 'Wheezing', 'Other Respiratory Symptoms', 'Palpitations', 'Chest Pains', 'Syncope', 'Orthopnea', 'Other Cardiovascular Symptoms', 'Nausea', 'Vomiting', 'Dysphagia', 'Heartburn', 'Change in Bowel Habits', 'Rectal Bleeding', 'Jaundice', 'Other Gastrointestinal Symptoms', 'Nocturia', 'Dysuria', 'Urinary Frequency', 'Hematuria', 'Other Genitourinary Symptoms', 'Excessive Sweating', 'Heat Intolerance', 'Polyuria', 'Excessive Thirst', 'Cold Intolerance', 'Other Endocrine Symptoms', 'History of Tuberculosis', 'History of Asthma', 'History of Diabetes', 'History of Hypertension', 'History of Psychiatric Consult', 'History of Cancer', 'Prior Surgeries/Hospitalizations', 'History of Allergies', 'Cancer Site in History', 'Prior Surgeries Or Hospitalization Dates', 'Prior Surgeries Or Hospitalization Reasons', 'Allergies in History', 'Other Past Medical History', 'Genogram (Describe Through Text)', 'Social And Environmental History', 'Last Menstrual Period (YYYY-MM-DD)', 'Previous Menstrual Period (YYYY-MM-DD)', 'Duration Of Menses', 'Interval Of Menses', 'Volume Of Menses', 'Menarche', 'Coitarche', 'DPT/Polio Immunization', 'HIB Immunization', 'Hepatitis B Immunization', 'MMR Immunization', 'Measles Immunization', 'Varicella Immunization', 'Pneumococcal Immunization', 'Influenza Immunization', 'Hepatitis A Immunization', 'DPT/Polio Doses', 'HIB Doses', 'Hepatitis B Doses', 'MMR Doses', 'Measles Doses', 'Varicella Doses', 'Pneumococcal Doses', 'Influenza Doses', 'Hepatitis A Doses', 'Other Immunizations', 'Activities', 'Drugs', 'Sexual Activity', 'Medications'], 
		['Dwelling Type (House, Apt.)', 'Number Of Household Members', 'Religion', 'Annual Family Income', 'Stakeholder', "Stakeholder's Interest In Issue", "Stakeholder's Role", "Stakeholder's Level Of Influence", 'Pertinent Beliefs', 'Impact On Family', 'Facilitating', 'Hindering', 'Burden Of Illness', 'Pertinent Legislation Or Policies', 'Personal And Social', 'Home', 'Education', 'Activities', 'Drugs', 'Sexual Activity', 'Family', 'Source Of Income And Dynamics', 'Additional Details Regarding History', 'Additional Details Regarding Context Including Ethical Considerations', 'History of Psychiatric Consult'], 
		['Nationality', 'Language', 'Religion', 'Pertinent Beliefs', 'Impact On Family', 'Facilitating', 'Hindering', 'Home', 'Education', 'Family', 'Additional Details Regarding Context Including Ethical Considerations'], 
		['Provocation', 'Timing', 'Concerns Regarding Problem', 'Impact On Family', 'Facilitating', 'Hindering', 'Burden Of Illness', 'Pertinent Legislation Or Policies', 'Fever', 'Weight Gain', 'Weight Loss', 'Weakness', 'Fatigue', 'Other General Symptoms', 'Rashes', 'Lumps', 'Sores', 'Itching', 'Muscle Pains', 'Joint Pains', 'Changes in Skin Color', 'Joint Swelling', 'Changes in Hair/Nails', 'Gout', 'Headache', 'Dizziness', 'Blurring of Vision', 'Tinnitus', 'Deafness', 'Nosebleeds', 'Frequent Colds', 'Hoarseness', 'Dry Mouth', 'Gum Bleeding', 'Enlarged Lymph Nodes', 'Dyspnea', 'Hemoptysis', 'Cough', 'Wheezing', 'Palpitations', 'Chest Pains', 'Syncope', 'Orthopnea', 'Nausea', 'Vomiting', 'Dysphagia', 'Heartburn', 'Change in Bowel Habits', 'Rectal Bleeding', 'Jaundice', 'Nocturia', 'Dysuria', 'Urinary Frequency', 'Hematuria', 'Excessive Sweating', 'Heat Intolerance', 'Polyuria', 'Excessive Thirst', 'Cold Intolerance', 'Duration Of Menses', 'Volume Of Menses', 'Home', 'Activities', 'Drugs', 'Sexual Activity', 'Family'], 
		['Chief Complaint', 'Concerns Regarding Problem', 'Additional Details Regarding History'], 
		['Other General Symptoms', 'Other Musculoskeletal or Dermatologic Symptoms', 'Other HEENT Symptoms', 'Other Respiratory Symptoms', 'Other Cardiovascular Symptoms', 'Other Gastrointestinal Symptoms', 'Other Genitourinary Symptoms', 'Other Endocrine Symptoms', 'Other Past Medical History', 'Other Family History', 'Concerns Regarding Problem', 'Additional Details Regarding History', 'Additional Details Regarding Context Including Ethical Considerations'], 
		['Chief Complaint', 'Specific', 'Physical/Physiological', 'Psychosocial/Emotional', 'Cultural Issues', 'Quality of Life Effect', 'Feelings', 'Additional']
	]
	
	# var json = JSON.new()
	# json.parse(mentorfieldscsv)
	# var response = json.get_data()
	
	# var mentorai_fields_file = FileAccess.open_encrypted_with_pass("user://mentorfields.dat", FileAccess.WRITE, "96iA!JxJtCRVhwpqj5z22ojKQK*&z3ZFSHRpLJ*GHBnrDJsxy9y5#P^4o4@sJe5uG*zK@L#WhydFvmP*rSbKwEen72qZ45AkxuNQ2qE*A&KJbLpFz4mao5fzeQ4R$p43")
	# var json_string = JSON.stringify(response)
	# mentorai_fields_file.store_line(json_string)
	# mentorai_fields_file.close()
	
	var patient = {}
	for i in range(len(Globals.patient.data.keys())):
		patient[Globals.patient.data.keys()[i]] = Globals.patient.data[Globals.patient.data.keys()[i]]

	var NA = ["", "Not Applicable", "N/A", "NA", "not applicable"]
	_mentor_fields = {
		"Introduction": {"Introduction":0},
		"Agenda": {"Agenda":0},
		"Consent": {"Consent":0},
		"Confidentiality": {"Confidentiality":0},
		"Privacy": {"Privacy":1},
		"Avoid Multiple": {"Avoid Multiple":1},
		"Order": {"Order": 1},
		"Recap": {"Recap":0},
		"Support": {"Support":0},
		"Closing": {"Closing":0},
	}
	
	for i in range(8):
		_mentor_fields[mentorfieldscsv[8][i]] = {}
		
		for field in mentorfieldscsv[i]:
			if patient[field] not in NA:
				_mentor_fields[mentorfieldscsv[8][i]][field] = 0


func get_overall_score() -> void:
	print("\nCriteria\t\tScore")
	for key in _mentor_fields.keys():
		var avg = 0
		for score in _mentor_fields[key].values():
			avg += float(score)
		print(key + ": " + str(avg/len(_mentor_fields[key])*100))
	
	_mentor_score = _mentor_fields
	
	_format_score()


# TODO: Make configurable
func _grade_response(mentor_response) -> void:
	var split_response = []
	for response in mentor_response.split("; "):
		split_response.append(response.split(":"))
	
	for response in split_response:
		for key in _mentor_fields.keys():
			if response[0] in _mentor_fields[key].keys():
				_mentor_fields[key][response[0]] = response[1]
		
		# Introduction
		if response[0] == "Introduction":
			if response[1] == "1":
				intro_started = true
				if not intro_first:
					_mentor_fields["Introduction"]["Introduction"] = 0
					_mentor_fields['Order']['Order'] = 0
			else:
				_mentor_fields["Introduction"]["Introduction"] = 0
				_mentor_fields['Order']['Order'] = 0
		
		print("Mentor Response:")
		print(response)
		if response[0] != "Introduction" and response[1] == "1":
			intro_first = false
		
		# Closing
		if response[0] == "Closing":
			closing_done = true
		if closing_done == false and closed == false:
			_mentor_fields["Closing"]["Closing"] = 0
			_mentor_fields['Order']['Order'] = 0
			closed = true
		
		# Check for order
		for item in _order_fields:
			if response[0] in item:
				current_order = _order_fields.find(item)
				
		# Set Order to 0 if out of sequence
		if current_order < prev_order:
			_mentor_fields['Order']['Order'] = 0
			print("Mentor : Order:0")
		
		prev_order = current_order


func _format_score() -> void:
	# Calculate scores
	var combined_scores = {}
	for key in _mentor_score.keys():
		var avg = 0
		for score in _mentor_score[key].values():
			avg += float(score)
		fields += key + "\n"
		scores += str(_round_place(avg/len(_mentor_score[key])*100, 2)) + "%\n"
		
		var arr_fields = fields.split("\n")
		var arr_scores = scores.split("\n")
		for i in range(len(arr_fields)):
			combined_scores[arr_fields[i]] = arr_scores[i]
	
	# Generate report (formatting)
	formatted_scores = ""
	for score in combined_scores:
		if score == "":
			continue
		
		formatted_scores += score + ": " + str(combined_scores[score]) + "\n"
	
	print(formatted_scores)


func _round_place(num, places) -> Variant:
	return (round(num * pow(10, places)) / pow(10, places))
