extends Node2D

signal module_complete(module, data, success)

@export var patient_model: PatientModel
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
var _stt_fails = 0

# Patient LLM
var _chat_http_request: HTTPRequest
var _chat_endpoint: String = "https://api.openai.com/v1/chat/completions"
var _chat_model: String = "ft:gpt-4o-mini-2024-07-18:ateneo-school-of-medicine-and-public-health:patient-eng-v11:Bb0jj7Oz"
var _chat_headers: PackedStringArray
var _chat_user_prompt = ""
var _messages = []
var _chat_convo = []
var _chat_context = []

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

	_on_audio_loaded_callback = JavaScriptBridge.create_callback(_on_audio_loaded)

	var audio_callback: JavaScriptObject = JavaScriptBridge.get_interface("audio_callback")

	audio_callback.dataLoaded = _on_audio_loaded_callback

	_on_transcript_loaded_callback = JavaScriptBridge.create_callback(_on_transcript_loaded)

	var transcript_callback: JavaScriptObject = JavaScriptBridge.get_interface("transcript_callback")

	transcript_callback.dataLoaded = _on_transcript_loaded_callback
	
	module_complete.connect(handleFailsafe)

	# Patient LLM
	_chat_http_request = HTTPRequest.new()
	add_child(_chat_http_request)
	_chat_http_request.timeout = 20
	_chat_http_request.request_completed.connect(_on_llm_request_completed)

	_load_patient_context()

	# Mentor LLM
	_mentor_http_request = HTTPRequest.new()
	add_child(_mentor_http_request)
	_mentor_http_request.timeout = 20
	_mentor_http_request.request_completed.connect(_on_mentor_request_completed)

	_load_mentor_context()
	
	# Mentor LLM Scoring
	var field_boundaries: Array = [0, 5, 25, 28, 33, 37, 43, 48, 57, 61, 67, 78, 90, 95, 100, 108, 113, 119, 132, 145, 152, 161, 171, 179, 190, 215, 216, 218]
	_order_fields = []
	for i in range(1, len(field_boundaries)):
		_order_fields.append(Globals.patient.data.keys().slice(field_boundaries[i-1], field_boundaries[i]))

	_get_mentor_fields()

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
	if not _interacted and Input.is_action_just_pressed("Record"):
		JavaScriptBridge.eval("startRecording();")
	elif not _interacted and Input.is_action_just_released("Record"):
		JavaScriptBridge.eval("stopRecording();")
		_interacted = true


func handleFailsafe(module, data, success) -> void:
	match module:
		"stt":
			if not success and _stt_fails < 3:
				# Inform user STT failed
				transcript.append_text("[System]: Speech-to-Text module failed to transcribe the audio. Retrying...\n")

				_stt_fails += 1

				# Retry sending STT
				call_stt(data)
			else:
				_stt_fails = 0
			
			if _stt_fails >= 3:
				_interacted = false
				#_stt_fails = 0

				transcript.append_text("[System]: Speech-to-Text module failed to transcribe the audio. Please try again.\n")
		"chat":
			if not success and _chat_fails < 3:
				# Inform user chat LLM failed
				transcript.append_text("[System]: Patient AI failed to generate a response. Retrying...\n")

				_chat_fails += 1
				
				# Retry sending chat LLM
				call_llm(data)
			else:
				_chat_fails = 0
			
			if _chat_fails >= 3:
				_interacted = false
				#_chat_fails = 0

				transcript.append_text("[System]: Patient AI failed to generate a response. Please try again.\n")
		"mentor":
			if not success:
				pass
				
				# (Optionally) inform user mentor LLM failed
				
				# Retry sending mentor LLM
		"tts":
			if not success and _tts_fails < 3:
				# Inform user TTS failed
				transcript.append_text("[System]: Text-to-Speech module failed to generate audio. Retrying...\n")

				_tts_fails += 1
				
				# Retry sending TTS
				call_tts(data)
			else:
				_tts_fails = 0

			if _tts_fails >= 3:
				_interacted = false
				#_tts_fails = 0
				transcript.append_text("[System]: Text-to-Speech module failed to generate audio after 3 attempts. Stopping TTS.\n")
				
				patient_model.play_idle()
				patient_model.face.stop()
				patient_model.face_play_default()
		_:
			printerr("Unknown module: " + module)


func _setup_modules() -> void:
	_setup_stt()
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
		2: # Local / Godot STT
			_stt_endpoint = ""
			_stt_headers = PackedStringArray([])
		_:
			printerr("Invalid STT option!")


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
		2: # Godot TTS
			_tts_endpoint = ""
			_tts_headers = PackedStringArray([])
		_:
			printerr("Invalid TTS option!")


func _on_enter_button_pressed() -> void:
	if not _interacted and enter_here.text != "":
		_interacted = true
		
		transcript.append_text("Doctor: " + enter_here.text + "\n")

		call_llm(enter_here.text)

		enter_here.text = ""


## Send audio to STT module to get the text
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
			pass


func _call_GoogleCloud_v1_stt(audio) -> void:
	JavaScriptBridge.eval("""callGoogleSTTv1(\'%s\', \'%d\', \'%s\');""" % [audio, _mix_rate, Globals.api_keys["GoogleCloud"]])


func _call_GoogleCloud_v2_stt(audio) -> void:
	JavaScriptBridge.eval("""callGoogleSTTv2(\'%s\', \'%s\', \'%d\', \'%s\', \'%s\');""" % [_stt_endpoint, _lang_code, _mix_rate, audio, Globals.google_auth_token])


## Sends text to the llm module to receive a response
func call_llm(text: String) -> void:
	_chat_user_prompt = text

	_call_ChatGPT(text)
	_call_mentor(text)


# Sends text to ChatGPT to receive a response
func _call_ChatGPT(text: String) -> void:
	patient_model.play_thinking()
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
		push_error("An error occurred in the HTTP request.")


func _call_mentor(text: String) -> void:
	_mentor_messages = _mentor_context.duplicate(true)
	_mentor_messages.append({
		"role": "user",
		"content": text
	})

	_mentor_convo.append({
		"role": "user",
		"content": text
	})

	var body: String = JSON.stringify({
		"messages": _mentor_messages,
		"model": _mentor_model,
		"frequency_penalty": freq_penalty,
		"max_tokens": max_tokens,
		"presence_penalty": presence_penalty,
		"stream": stream,
		"temperature": temp
	})

	var error: int = _mentor_http_request.request(_mentor_endpoint, _mentor_headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		push_error("An error occurred in the HTTP request to the mentor.")


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

	_tts_http_request.request(_tts_endpoint, _tts_headers, HTTPClient.METHOD_POST, body)


func _on_stt_request_completed(result, response_code, request_headers, body) -> void:
	pass


func _on_llm_request_completed(result, response_code, request_headers, body) -> void:
	# Check if the HTTP request timed out
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("ChatGPT request timed out!")

		module_complete.emit("chat", _chat_user_prompt, false)
		return
	
	# Check if there was an error in the HTTP request response
	if response_code != 200:
		print("There was an error with ChatGPT's response, response code:" + str(response_code))
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

	# Append the text to _messages for submission to ChatGPT and _convo for storage to a local transcript
	_messages.append({
		"role": "assistant",
		"content": message["content"]
	})
	_chat_convo.append({
		"role": "Patient",
		"content": message["content"]
	})

	transcript.append_text("Patient: " + message["content"] + "\n")

	module_complete.emit("chat", _chat_user_prompt, true)

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


func _on_mentor_request_completed(result, response_code, request_headers, body) -> void:
	# Check if the HTTP request timed out
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("Mentor AI request timed out!")
		return
	
	# Check if there was an error in the HTTP request response
	if response_code != 200:
		print("There was an error with the Mentor AI's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())
		return

	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	var message = response["choices"][0]["message"]

	mentor_comment.text = message["content"]

	_mentor_convo.append({
		"role": "assistant",
		"content": message["content"]
	})
	
	_grade_response(message["content"])


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


func _on_audio_loaded(data: Array) -> void:
	if data.size() == 0:
		return
	
	var json: JSON = JSON.new()
	var json_parse_result: int = json.parse(data[0])
	if not json_parse_result == OK:
		printerr("patient info can't be parsed as a json object")
		return
	
	var dup = json.data.duplicate(true)
	_stt_audio = dup["audio"]
	call_stt(dup["audio"])


func _on_transcript_loaded(data: Array) -> void:
	if data.size() == 0:
		return
	
	var json: JSON = JSON.new()
	var json_parse_result: int = json.parse(data[0])
	if not json_parse_result == OK:
		printerr("patient info can't be parsed as a json object")
		return
	
	var dup = json.data.duplicate(true)

	match dup["result"]:
		"No Audio":
			print("No audio detected in the recording!")
			module_complete.emit("stt", _stt_audio, false)
		"Unintelligible":
			print("Audio is unintelligible!")
			module_complete.emit("stt", _stt_audio, false)
		_:
			# Transcript was successfully generated
			module_complete.emit("stt", _stt_audio, true)
			call_llm(dup["result"])


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


func _load_patient_context() -> void:
	var headers = Globals.patient.data.keys()

	print(headers.size())

	# Add extra context if personality is set to Aggressive
	var aggression = ""
	if Globals.personality == 2:
		aggression = "This is a sensitive question and you must answer aggressively and defensively. You are an uncooperative and aggressive patient that must answer questions very shortly and to the point but must be defensive when asked about sensitive topics. Add phrases like 'that's personal', or 'you're asking too many questions', or 'that's none of your business', or 'why are you even asking me that'. "
	
	# Pick a name from a list of names for the patient
	var NA = ["", "Not Applicable", "N/A", "NA", "not applicable"]
	var f_names = ["Alex", "Bailey", "Casey", "Devin", "Emerson", "Finley", "Gray", "Hayden", "Indigo", "Jordan", "Kai", "Logan", "Morgan", "Nico", "Oakley", "Phoenix", "Quinn", "Reese", "Skyler", "Taylor", "Umi", "Vaughn", "Wren", "Xoan", "Yael", "Zephyr"]
	var l_names = ["Anderson", "Bailey", "Carter", "Dawson", "Ellis", "Finch", "Garland", "Hayes", "Irwin", "Jensen", "Kennedy", "Lawson", "Monroe", "Nolan", "Oakley", "Parker", "Quinn", "Reed", "Sawyer", "Taylor", "Underwood", "Vega", "Wallace", "Xavier", "Young", "Zimmerman"]
	
	# BASIC INFO
	var _name_first = f_names[(Globals.patient.data[headers[0]].unicode_at(0))-65]
	var _name_last = l_names[(Globals.patient.data[headers[1]].unicode_at(0))-65]
	var _doc_first = f_names[(Globals.patient.data[headers[2]].unicode_at(0))-65]
	var _doc_last = l_names[(Globals.patient.data[headers[3]].unicode_at(0))-65]
	
	_messages += [
		{"role": "system", "content": "You are a patient named %s %s. You are visiting for a consultation." % [_name_first, _name_last]}, # Globals.patient.info[0], Globals.patient.info[1]
		{"role": "system", "content": "Your attending physician is %s %s." % [_doc_first, _doc_last]} # Globals.patient.info[2], Globals.patient.info[3]
	]

	# PESRONAL AND SOCIAL HISTORY
	if Globals.patient.data[headers[5]] not in NA:
		_messages += [{"role": "system", "content": "Your birthday is %s (YYYY-MM-DD). You must answer in the format 'Month Day, Year'." % [Globals.patient.data[headers[5]]]}]
	else:
		_messages += [{"role": "system", "content": "You must say that you do not want to share your birth date."}]
	
	var _language_formatted
	# if Globals.allow_select_language:
	# 	_language_formatted = Globals.patient_language if Globals.patient_language == "English" else ("Filipino" if Globals.patient_language == "Tagalog" else ("either English or Filipino"))
	# else:
	# 	_language_formatted = Globals.patient.data[headers[22]] if Globals.patient.data[headers[22]] == "English" or Globals.patient.data[headers[22]] == "Filipino" else "either English or Filipino"
	_language_formatted = Globals.patient.data[headers[22]] if Globals.patient.data[headers[22]] == "English" or Globals.patient.data[headers[22]] == "Filipino" else "either English or Filipino"
	
	for i in range(6, 25):
		if headers[i] == "Language":
			_messages += [{"role": "system", "content": "You must only use %s when communicating, use this language when communicating. When you are asked a question in a different language, you must act confused. When you are asked to speak in a different language than %s, you must deny the request. You should answer concisely, do not give out too much information in one response." % [_language_formatted, _language_formatted]}]
		elif Globals.patient.data[headers[i]] not in NA:
			_messages += [{"role": "system", "content": "%sYour %s is %s." % [aggression if headers[i] in ['Dwelling Type (House, Apt.)', 'Number Of Rooms', 'Appliances (Radio, Tv, Refrigerator) *Can Be Multiple', 'Annual Family Income'] else "", headers[i], Globals.patient.data[headers[i]]]}]
		else:
			_messages += [{"role": "system", "content": "%sYour %s is not known. You must say that you do not know %s." % [aggression if headers[i] in ['Dwelling Type (House, Apt.)', 'Number Of Rooms', 'Appliances (Radio, Tv, Refrigerator) *Can Be Multiple', 'Annual Family Income'] else "", headers[i], Globals.patient.data[headers[i]]]}]
	
	# PQRST PAIN ASSESSMENT
	_messages += [
		{"role": "system", "content": "The provocation of your pain is %s." % [Globals.patient.data[headers[28]]]},
		{"role": "system", "content": "The quality of your pain is %s." % [Globals.patient.data[headers[29]]]},
		{"role": "system", "content": "The region of your pain is %s." % [Globals.patient.data[headers[30]]]},
		{"role": "system", "content": "The severity of your pain is %s/10." % [Globals.patient.data[headers[31]]]},
		{"role": "system", "content": "The timing of your pain is %s." % [Globals.patient.data[headers[32]]]}
	]

	# HISTORY
	_messages += [
		{"role": "system", "content": "Your most important complaint and reason for consulting is %s." % [Globals.patient.data[headers[25]]]},
		{"role": "system", "content": "Your main concerns about the problem is/are %s." % [Globals.patient.data[headers[26]]]}
	]

	print("History")
	print(Globals.patient.history)

	if Globals.patient.history:
		var temp_history_str = ""
		for hist in Globals.patient.history:
			
			if hist[0] not in NA and hist[1] not in NA:
				_messages += [{"role": "system", "content": "Your history of present illness includes: %s with dosage of %s." % [hist[0], hist[1]]}]
			if hist[0] not in NA and hist[1] in NA:
				_messages += [{"role": "system", "content": "Your history of present illness includes: %s." % [hist[0]]}]
	else:
		_messages += [{"role": "system", "content": "Your history of present illness is not known. You must say that you do not know your history of present illness."}]
	
	# CONTEXT: STAKEHOLDER ANALYSIS
	if Globals.patient.data[headers[33]] not in NA:
		_messages += [{"role": "system", "content": "%s is a decision maker for your medicinal treatment." % [Globals.patient.data[headers[33]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not sure about your stakeholders. You must say that you do not know about your treatment's stakeholders."}]
	if Globals.patient.data[headers[34]] not in NA:
		_messages += [{"role": "system", "content": "Your stakeholder is a %s for your medicinal treatment." % [Globals.patient.data[headers[34]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know about your stakeholder's interest in your issue. You must say that you do not know how important your stakeholder is in deciding your treatment."}]
	if Globals.patient.data[headers[35]] not in NA:
		_messages += [{"role": "system", "content": "Your stakeholder's role is %s." % [Globals.patient.data[headers[35]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not sure about your stakeholder's role. You must say that you do not know about your stakeholder's role."}]
	if Globals.patient.data[headers[36]] not in NA:
		_messages += [{"role": "system", "content": "The influence of your stakeholder's opinion on your treatment planning is %s." % [Globals.patient.data[headers[36]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware your stakeholder's level of influence over your treatment planning. You must say that you do not know how much your stakeholder's opinions affect your treatment planning."}]
	
	# CONTEXT: COMMUNITY FACTORS
	if Globals.patient.data[headers[37]] not in NA:
		_messages += [{"role": "system", "content": "You have pertinent belief/s, such as %s." % [Globals.patient.data[headers[37]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not have any pertinent beliefs. You must say that you do not want to talk about your beliefs."}]
	if Globals.patient.data[headers[38]] not in NA:
		_messages += [{"role": "system", "content": "%sThis will have a %s impact on your family." % [aggression, Globals.patient.data[headers[38]]]}]
	else:
		_messages += [{"role": "system", "content": "%sYou do not know about community factors that influence your family. You must say that you do not know of any community factors that influence your family." % [aggression]}]
	if Globals.patient.data[headers[39]] not in NA:
		_messages += [{"role": "system", "content": "Factors in the community like %s facilitate and help you." % [Globals.patient.data[headers[39]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware of any factors in the community that facilitate and help you. You must say that you do not know of any community factors that help you."}]
	if Globals.patient.data[headers[40]] not in NA:
		_messages += [{"role": "system", "content": "Factors in the community like %s hinder you." % [Globals.patient.data[headers[40]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware of any factors in the community that hinder you. You must say that you do not know of any community factors that hinder you."}]
	if Globals.patient.data[headers[41]] not in NA:
		_messages += [{"role": "system", "content": "Your illness gives you burdens like %s." % [Globals.patient.data[headers[41]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware of any burdens that your illness gives you. You must say that you do not know if your illness gives you burdens."}]
	if Globals.patient.data[headers[42]] not in NA:
		_messages += [{"role": "system", "content": "%s are pertinent legislations or policies that affect you." % [Globals.patient.data[headers[42]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware of any pertinent legislation or policies. You must say that you do not know anything about relevant legislation or policies."}]
	
	# NUTRITIONAL HISTORY
	if Globals.patient.data[headers[43]] not in NA:
		_messages += [{"role": "system", "content": "You were breastfed until %s." % [Globals.patient.data[headers[43]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know how long you were breastfed. You must say that you do not know how long you were breastfed."}]
	if Globals.patient.data[headers[44]] not in NA:
		_messages += [{"role": "system", "content": "You were given %s formula as a baby." % [Globals.patient.data[headers[44]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know about your consumption of formula as a baby. You must say that you don't remember anything about consuming formula as a baby."}]
	if Globals.patient.data[headers[45]] not in NA:
		_messages += [{"role": "system", "content": "You were weaned at %s." % [Globals.patient.data[headers[45]]]}]
	else:
		_messages += [{"role": "system", "content": "Your weaning age is unknown. You must say that you do not know when you transitioned from breast milk to food."}]
	if Globals.patient.data[headers[46]] not in NA:
		_messages += [{"role": "system", "content": "Your current diet is %s." % [Globals.patient.data[headers[46]]]}]
	else:
		_messages += [{"role": "system", "content": "You must say that you are not sure about your current diet."}]
	if Globals.patient.data[headers[47]] not in NA:
		_messages += [{"role": "system", "content": "Your food allergy/ies is/are %s." % [Globals.patient.data[headers[47]]]}]
	else:
		_messages += [{"role": "system", "content": "Your food allergies are unknown. You must say that you do not know if you have any food allergies."}]

	# BIRTH MATERNAL
	if Globals.patient.data[headers[48]] not in NA:
		_messages += [{"role": "system", "content": "Your mother's pregnancy was %s." % [Globals.patient.data[headers[48]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know anything about your mother's term. You must say you do not know how many weeks your mother carried you."}]
	if Globals.patient.data[headers[49]] not in NA:
		_messages += [{"role": "system", "content": "Your mother gave birth to you via %s." % [Globals.patient.data[headers[49]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know how you were delivered. You must say you do not know how you were born."}]
	if Globals.patient.data[headers[50]] not in NA:
		_messages += [{"role": "system", "content": "Your mother was %s years old when she gave birth to you." % [Globals.patient.data[headers[50]]]}]
	else:
		_messages += [{"role": "system", "content": "You must say that you do not know how old your mother was when she gave birth to you."}]
	if Globals.patient.data[headers[51]] not in NA:
		_messages += [{"role": "system", "content": "Your mother has been pregnant %s times. Your mother's gravidity is %s" % [Globals.patient.data[headers[51]], Globals.patient.data[headers[51]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know how many times your mother has been pregnant."}]
	if Globals.patient.data[headers[52]] not in NA:
		_messages += [{"role": "system", "content": "Your mother has carried a pregnancy to at least 20 weeks %s times." % [Globals.patient.data[headers[52]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know how many times your mother has carried a pregnancy to at least 20 weeks."}]
	if Globals.patient.data[headers[53]] not in NA:
		_messages += [{"role": "system", "content": "Your weight when you were born is %s grams." % [Globals.patient.data[headers[53]]]}]
	else:
		_messages += [{"role": "system", "content": "Your birth weight is unknown. You must say that you do not know how heavy you were when you were born."}]
	if Globals.patient.data[headers[54]] not in NA and Globals.patient.data[headers[55]] not in NA:
		_messages += [{"role": "system", "content": "The doctor that attended to your mother during giving birth is %s %s." % [Globals.patient.data[headers[54]], Globals.patient.data[headers[55]]]}]
	else:
		_messages += [{"role": "system", "content": "Your mother's attending doctor during childbirth is unknown."}]
	if Globals.patient.data[headers[56]] not in NA:
		_messages += [{"role": "system", "content": "Your mother's perinatal cervix is %s." % [Globals.patient.data[headers[56]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know anything about your mother's perinatal cervix when you were born."}]
	
	# DEVELOPMENT MILESTONES
	for i in range(57, 61):
		if Globals.patient.data[headers[i]] not in NA:
			_messages += [{"role": "system", "content": "Your %s developmental milestones are %s." % [headers[i], Globals.patient.data[headers[i]]]}]
		else:
			_messages += [{"role": "system", "content": "Your %s development milestone is unknown. You must say that you do not know about your %s development." % [headers[i], Globals.patient.data[headers[i]]]}]

	# REVIEW OF SYSTEMS: GENERAL SYMPTOMS
	for i in range(61, 66):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "You have %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "You don't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[66]] not in NA:
		_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[66]]]}]
	else:
		_messages += [{"role": "system", "content": "Your other general symptoms are unknown. You must say that you do not have any other general symptoms."}]
	
	# REVIEW OF SYMPTOMS: MUSCULOSKELETAL OR DERMATOLOGIC
	for i in range(67, 77):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "You have %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "You don't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[77]] not in NA:
		_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[77]]]}]
	else:
		_messages += [{"role": "system", "content": "Your other musculoskeletal or dermatologic symptoms are unknown. You must say that you do not have any other symptoms that affect your muscles, bones, or skin."}]
	
	# GENERAL SYMPTOMS: HEENT
	for i in range(78, 89):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "You have %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "You don't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[89]] not in NA:
		_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[89]]]}]
	else:
		_messages += [{"role": "system", "content": "Your other HEENT symptoms are unknown. You must say that you do not have any other symptoms concerning your head, eyes, ears, nose, or throat."}]

	if Globals.patient.data[headers[90]] == 'Yes':
		_messages += [{"role": "system", "content": "You have shortness of breath"}]
	else:
		_messages += [{"role": "system", "content": "You don't have shortness of breath."}]
	if Globals.patient.data[headers[91]] == 'Yes':
		_messages += [{"role": "system", "content": "You cough up blood"}]
	else:
		_messages += [{"role": "system", "content": "You don't cough up blood."}]
	
	for i in range(92, 94):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "You have %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "You don't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[94]] not in NA:
		_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[94]]]}]
	else:
		_messages += [{"role": "system", "content": "Your other respiratory symptoms are unknown. You must say that you do not have any other symptoms that affect your breathing."}]
	
	# GENERAL SYMPTOMS: CARDIOVASCULAR
	for i in range(95, 97):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "You have %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "You don't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[97]] not in NA:
		_messages += [{"role": "system", "content": "You faint."}]
	else:
		_messages += [{"role": "system", "content": "You don't faint."}]
	if Globals.patient.data[headers[98]] not in NA:
		_messages += [{"role": "system", "content": "You have shortness of breath while lying on your back."}]
	else:
		_messages += [{"role": "system", "content": "You don't have shortness of breath when lying on your back."}]

	if Globals.patient.data[headers[99]] not in NA:
		_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[99]]]}]
	else:
		_messages += [{"role": "system", "content": "Your other cardiovascular symptoms are unknown. You must say that you do not have any other symptoms that affect your heart or blood."}]
	
	# GENERAL SYMPTOMS: GASTROINTESTINAL
	for i in range(100, 107):
		if headers[i] == 'Dysphagia':
			if Globals.patient.data[headers[i]] == 'Yes':
				_messages += [{"role": "system", "content": "You have difficulty swallowing."}]
			else:
				_messages += [{"role": "system", "content": "You don't have difficulty swallowing."}]
		else:
			if Globals.patient.data[headers[i]] == 'Yes':
				_messages += [{"role": "system", "content": "You have %s." % [headers[i]]}]
			else:
				_messages += [{"role": "system", "content": "You don't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[107]] not in NA:
		_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[107]]]}]
	else:
		_messages += [{"role": "system", "content": "Your other gastrointestinal symptoms are unknown. You must say that you do not have any other symptoms that affect your digestion."}]
	
	# GENERAL SYMPTOMS: GENITOURINARY
	if Globals.patient.data[headers[108]] == 'Yes':
		_messages += [{"role": "system", "content": "You pee a lot during the night"}]
	else:
		_messages += [{"role": "system", "content": "You don't pee a lot during the night ."}]
	if Globals.patient.data[headers[109]] == 'Yes':
		_messages += [{"role": "system", "content": "You have pain when you pee."}]
	else:
		_messages += [{"role": "system", "content": "You don't have pain when you pee."}]
	if Globals.patient.data[headers[110]] == 'Yes':
		_messages += [{"role": "system", "content": "You pee more often than average"}]
	else:
		_messages += [{"role": "system", "content": "You don't pee more often than average ."}]
	if Globals.patient.data[headers[111]] == 'Yes':
		_messages += [{"role": "system", "content": "You have blood in your urine"}]
	else:
		_messages += [{"role": "system", "content": "You don't have blood in your urine."}]
	
	if Globals.patient.data[headers[112]] not in NA:
		_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[112]]]}]
	else:
		_messages += [{"role": "system", "content": "Your other genitourinary symptoms are unknown. You must say that you do not have any other symptoms that affect your urine or your reproductive system."}]
	
	# GENERAL SYMPTOMS: ENDOCRINE
	for i in range(113, 118):
		if headers[i] == "Polyuria":
			if Globals.patient.data[headers[i]] == 'Yes':
				_messages += [{"role": "system", "content": "You pee more than the average amount"}]
			else:
				_messages += [{"role": "system", "content": "You don't pee more than the average amount ."}]
		else:
			if Globals.patient.data[headers[i]] == 'Yes':
				_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[i]]]}]
			else:
				_messages += [{"role": "system", "content": "You don't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[118]] not in NA:
		_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[118]]]}]
	else:
		_messages += [{"role": "system", "content": "Your other endocrine symptoms are unknown. You must say that you do not know any other symptoms that affect your hormones."}]
	
	# PAST MEDICAL HISTORY
	for i in range(119, 127):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "%sYou have %s." % [aggression if headers[i] in ['History of Diabetes', 'History of Psychiatric Consult', 'History of Cancer', 'Prior Surgeries/Hospitalizations'] else "", Globals.patient.data[headers[i]]]}]
		else:
			_messages += [{"role": "system", "content": "%sYou don't have %s." % [aggression if headers[i] in ['History of Diabetes', 'History of Psychiatric Consult', 'History of Cancer', 'Prior Surgeries/Hospitalizations'] else "", headers[i]]}]
	
	if Globals.patient.data[headers[131]] not in NA:
		_messages += [{"role": "system", "content": "You have %s." % [Globals.patient.data[headers[131]]]}]
	else:
		_messages += [{"role": "system", "content": "Your other past medical history is unknown. You must say that you are not sure about your past medical history."}]
	if Globals.patient.data[headers[127]] not in NA:
		_messages += [{"role": "system", "content": "You had cancer before at %s." % [Globals.patient.data[headers[127]]]}]
	else:
		_messages += [{"role": "system", "content": "Your previous cancer sites are unknown. You must say that you are not sure about previous cancer sites."}]
	if Globals.patient.data[headers[128]] not in NA:
		_messages += [{"role": "system", "content": "You had prior surgeries or hospitalization dates on %s." % [Globals.patient.data[headers[128]]]}]
	else:
		_messages += [{"role": "system", "content": "Your prior surgeries or hospitalization dates are unknown. You must say that you do not remember your prior surgeries or hospitalization dates."}]
	if Globals.patient.data[headers[129]] not in NA:
		_messages += [{"role": "system", "content": "%sYou have had prior surgeries or hospitalization because of %s." % [aggression, Globals.patient.data[headers[129]]]}]
	else:
		_messages += [{"role": "system", "content": "%sYour prior surgeries or hospitalization reasons are unknown. You must say that you do not remember the reasons for your prior surgeries or hospitalizations." % [aggression]}]
	if Globals.patient.data[headers[130]] not in NA:
		_messages += [{"role": "system", "content": "You had history of allergies with %s." % [Globals.patient.data[headers[130]]]}]
	else:
		_messages += [{"role": "system", "content": "Your history of allergies is unknown. You must say that you do not know about your history of allergies."}]
	
	# FAMILY MEDICAL HISTORY
	for i in range(132, 139):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "%sYou have %s." % [aggression if headers[i] in ['Family History of Psychiatric Consult', 'Family History of Diabetes', 'Family History of Cardiovascular Disease', 'Family History of Cancer'] else "", headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "%sYou don't have %s." % [aggression if headers[i] in ['Family History of Psychiatric Consult', 'Family History of Diabetes', 'Family History of Cardiovascular Disease', 'Family History of Cancer'] else "", headers[i]]}]
	
	if Globals.patient.data[headers[140]] not in NA:
		if Globals.patient.data[headers[139]] not in NA:
			_messages += [{"role": "system", "content": "Your %s has had cancer before at %s." % [Globals.patient.data[headers[140]], Globals.patient.data[headers[139]]]}]
		else:
			_messages += [{"role": "system", "content": "Your %s has had cancer before." % [Globals.patient.data[headers[140]]]}]
	else:
		_messages += [{"role": "system", "content": "Your relationship to any cancer patient is unknown. You must say that you do not know if any of your relatives have cancer or have had cancer."}]
	if Globals.patient.data[headers[141]] not in NA:
		_messages += [{"role": "system", "content": "Your family has had history of allergies with %s." % [Globals.patient.data[headers[141]]]}]
	else:
		_messages += [{"role": "system", "content": "Your family's history of allergies is unknown. You must say that you do not know about your family's history of allergies."}]
	if Globals.patient.data[headers[142]] not in NA:
		_messages += [{"role": "system", "content": "Your other family history is %s." % [Globals.patient.data[headers[142]]]}]
	else:
		_messages += [{"role": "system", "content": "Other details about your family history are unknown. You must say that you do not know about any other details about your family history."}]
	if Globals.patient.data[headers[143]] not in NA:
		_messages += [{"role": "system", "content": "Your genogram can be described as %s." % [Globals.patient.data[headers[143]]]}]
	else:
		_messages += [{"role": "system", "content": "Your genogram is unknown. You must say that you do not know about your family genogram."}]
	if Globals.patient.data[headers[144]] not in NA:
		_messages += [{"role": "system", "content": "Your social and environmental history can be described as %s." % [Globals.patient.data[headers[144]]]}]
	else:
		_messages += [{"role": "system", "content": "Your social and environmental history is unknown. You must say that you do not remember your social and environmental history."}]
	
	# GYNECOLOGIC HISTORY
	if Globals.patient.data[headers[7]] == 'Female' and Globals.patient.data[headers[150]] not in NA:
		if Globals.patient.data[headers[145]] not in NA:
			_messages += [{"role": "system", "content": "%sThe start of your last period or the first day of bleeding is %s." % [aggression, Globals.patient.data[headers[145]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe start of your last period or your first day of bleeding is unknown. You must say that you do not remember the start of your last period or your first day of bleeding." % [aggression]}]
		if Globals.patient.data[headers[146]] not in NA:
			_messages += [{"role": "system", "content": "%sThe starting date of your period before your last is %s." % [aggression, Globals.patient.data[headers[146]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe starting date of your period before your last is unknown. You must say that you do not remember the starting date of your period before your last." % [aggression]}]
		if Globals.patient.data[headers[147]] not in NA:
			_messages += [{"role": "system", "content": "%sThe duration of period bleeding is %s." % [aggression, Globals.patient.data[headers[147]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe duration of your period bleeding is unknown. You must say that you are not sure about how long your period bleeding lasts." % [aggression]}]
		if Globals.patient.data[headers[148]] not in NA:
			_messages += [{"role": "system", "content": "%sThe interval of your period cycles or how long each cycle takes is %s." % [aggression, Globals.patient.data[headers[148]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe interval of your period cycles or how long each cycle takes is unknown. You must say that you are not sure about how long each cycle takes." % [aggression]}]
		if Globals.patient.data[headers[149]] not in NA:
			_messages += [{"role": "system", "content": "%sYou bleed %s mL during your period or menses." % [aggression, Globals.patient.data[headers[149]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe amount you bleed during your period or menses is unknown. You must say that you are not sure about how much blood you expel during your period." % [aggression]}]
		if Globals.patient.data[headers[150]] not in NA:
			_messages += [{"role": "system", "content": "%sYou were %s years old when you got your first period." % [aggression, Globals.patient.data[headers[150]]]}]
		else:
			_messages += [{"role": "system", "content": "%sYour menarche or age when you got your first period is unknown. You must say that you do not know when you had your first period." % [aggression]}]
		if Globals.patient.data[headers[151]] not in NA:
			_messages += [{"role": "system", "content": "%sYou were %s years old during your first sexual intercourse." % [aggression, Globals.patient.data[headers[151]]]}]
		else:
			_messages += [{"role": "system", "content": "%sYour coitarche or age during your first sexual intercourse is unknown. You must say that you are unsure about the first time you had sex." % [aggression]}]
	
	# IMMUNIZATIONS
	for i in range(152, 161):
		if Globals.patient.data[headers[i]] == 'Complete' or Globals.patient.data[headers[i]] == 'Incomplete':
			_messages += [{"role": "system", "content": "You have completed the doses for %s %s." % [Globals.patient.data[headers[i]], headers[i]]}]
		elif Globals.patient.data[headers[i]] == 'None':
			_messages += [{"role": "system", "content": "You don't have %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "You are unsure about having %s. You must say that you do not know if you have %s." % [headers[i], headers[i]]}]
	
	# IMMUNIZATION DOSES
	for i in range(161, 170):
		if Globals.patient.data[headers[i]] not in NA:
			_messages += [{"role": "system", "content": "You have had %s doses for %s." % [Globals.patient.data[headers[i]], headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "Your doses for %s is unknown. You must say that you do not know how many %s you have had.." % [headers[i], headers[i]]}]
	
	print("Immunizations:")
	print(Globals.patient.immunizations)

	if Globals.patient.immunizations:
		for immune in Globals.patient.immunizations:
			_messages += [{"role": "system", "content": "You have %s doses of %s immunization." % [immune[1], immune[0]]}]
	else:
		_messages += [{"role": "system", "content": "Your other immunizations are unknown. You must say that you are not sure about your other immunizations."}]
	
	# ADOLESCENT INTERVIEW
	if 10 <= int(Globals.patient.data[headers[6]]) and int(Globals.patient.data[headers[6]]) <= 19:
		if Globals.patient.data[headers[171]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about your home, answer with %s." % [aggression, Globals.patient.data[headers[171]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about your home is unknown. You must say that you do not want to talk about your home." % [aggression]}]
		if Globals.patient.data[headers[172]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about your education, answer with %s." % [aggression, Globals.patient.data[headers[172]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about your education is unknown. You must say that you do not want to talk about your education." % [aggression]}]
		if Globals.patient.data[headers[173]] not in NA:
			_messages += [{"role": "system", "content": "When asked about your activities, answer with %s." % [Globals.patient.data[headers[173]]]}]
		else:
			_messages += [{"role": "system", "content": "Information about your activities is unknown. You must say that you do not want to talk about what you do."}]
		if Globals.patient.data[headers[174]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about drugs you have taken, answer with %s." % [aggression, Globals.patient.data[headers[174]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about drugs you have taken is unknown. You must say that you do not want to talk about drugs." % [aggression]}]
		if Globals.patient.data[headers[175]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked if you have had any kind of sexual activity or anything about it, answer with %s." % [aggression, Globals.patient.data[headers[175]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about if you had any kind of sexual activity or anything about it is unknown. You must say that you do not want to talk about your sex life." % [aggression]}]
		if Globals.patient.data[headers[176]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about your history with suicide/depression, answer with %s." % [aggression, Globals.patient.data[headers[176]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about your history with suicide/depression is unknown. You must say that you do not want to talk about your suicide or depression." % [aggression]}]
		if Globals.patient.data[headers[177]] not in NA:
			_messages += [{"role": "system", "content": "When asked about your family, answer with %s." % [Globals.patient.data[headers[177]]]}]
		else:
			_messages += [{"role": "system", "content": "Information about your family is unknown. You must say that you do not want to talk about your family."}]
		if Globals.patient.data[headers[178]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about your source of income and dynamics, answer with %s." % [aggression, Globals.patient.data[headers[178]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about your source of income and dynamics is unknown. You must say that you do not want to talk about your source of income and dynamics." % [aggression]}]
	
	# NEUROPSYCHIATRIC EXAM
	# ['General Appearance', 'General Behavior', 'Attitude Towards Examiner', 'Mood', 'Affect', 'Speech', 'Perceptual Disturbance', 'Stream of Thought', 'Thought Content', 'Impulse Control', 'Intellectual Capacity Global Estimate']
	if Globals.patient.data[headers[179]] not in NA:
		_messages += [{"role": "system", "content": "Your general appearance is that you are %s." % [Globals.patient.data[headers[179]]]}]
	else:
		_messages += [{"role": "system", "content": "Your general appearance is unremarkable."}]
		
	if Globals.patient.data[headers[180]] not in NA:
		if Globals.patient.data[headers[180]] == 'Normal':
			_messages += [{"role": "system", "content": "Your general behavior is normal."}]
		else:
			_messages += [{"role": "system", "content": "You are experiencing %s" % [Globals.patient.data[headers[180]]]}]
	else:
		_messages += [{"role": "system", "content": "Your general behavior is unremarkable."}]
	
	if Globals.patient.data[headers[181]] not in NA:
		_messages += [{"role": "system", "content": "You are %s towards the examiner." % [Globals.patient.data[headers[181]]]}]
	else:
		_messages += [{"role": "system", "content": "Your attitude towards the examiner is unremarkable."}]
	
	if Globals.patient.data[headers[182]] not in NA:
		_messages += [{"role": "system", "content": "You are feeling %s" % [Globals.patient.data[headers[182]]]}]
	else:
		_messages += [{"role": "system", "content": "Your mood is unremarkable."}]
	
	if Globals.patient.data[headers[183]] not in NA:
		var affect = Globals.patient.data[headers[183]]
		if affect == 'Inappropriate':
			_messages += [{"role": "system", "content": "You are demonstrating emotions that do not fit the context."}]
		elif affect == 'Appropriate':
			_messages += [{"role": "system", "content": "You are demonstrating emotions that fit the context."}]
		elif affect == 'Restricted':
			_messages += [{"role": "system", "content": "You are demonstrating a narrow range of emotions."}]
		elif affect == 'Blunted':
			_messages += [{"role": "system", "content": "You are demonstrating a limited intensity of emotions."}]
		elif affect == 'Flat':
			_messages += [{"role": "system", "content": "You are not demonstrating any emotions."}]
		elif affect == 'Broad':
			_messages += [{"role": "system", "content": "You are able to demonstrate a broad range of emotions."}]
	else:
		_messages += [{"role": "system", "content": "Your affect is unremarkable."}]
	
	if Globals.patient.data[headers[184]] not in NA:
		_messages += [{"role": "system", "content": "Your speech is %s." % [Globals.patient.data[headers[184]]]}]
	else:
		_messages += [{"role": "system", "content": "Your speech is unremarkable."}]
	
	if Globals.patient.data[headers[185]] not in NA:
		var perceptualDisturbance = Globals.patient.data[headers[185]]
		if perceptualDisturbance == 'Derealization':
			_messages += [{"role": "system", "content": "You feel detached from your surroundings."}]
		elif perceptualDisturbance == 'Depersonalization':
			_messages += [{"role": "system", "content": "You feel detached and disconnected from your self."}]
		elif perceptualDisturbance == 'Hallucinations':
			_messages += [{"role": "system", "content": "You are having hallucinations."}]
		elif perceptualDisturbance == 'None':
			_messages += [{"role": "system", "content": "You are not experiencing any perceptual disturbances."}]
	else:
		_messages += [{"role": "system", "content": "You don't remember any perceptual disturbances."}]
	
	if Globals.patient.data[headers[186]] not in NA:
		var stream_str = Globals.patient.data[headers[186]]
		if stream_str == 'Tangentiality':
			_messages += [{"role": "system", "content": "Your ideas are connected but you tend to go far off-topic without returning to the initial topic."}]
		if stream_str == 'Paucity of Thought':
			_messages += [{"role": "system", "content": "You are experiencing a paucity of thoughts."}]
		if stream_str == 'Flight of Ideas':
			_messages += [{"role": "system", "content": "You talk quickly and erratically, jumping between ideas and thoughts."}]
		if stream_str == 'Looseness of Association':
			_messages += [{"role": "system", "content": "Your ideas lack connection."}]
		if stream_str == 'Goal Oriented':
			_messages += [{"role": "system", "content": "Your thoughts progress linearly without veering from the subject at hand."}]
	else:
		_messages += [{"role": "system", "content": "Your stream of thought is unremarkable."}]
	
	if Globals.patient.data[headers[187]] not in NA:
		var thought = Globals.patient.data[headers[187]]
		if thought == 'Suicidal':
			_messages += [{"role": "system", "content": "You are experiencing suicidal thoughts."}]
		if thought == 'Bizzare':
			_messages += [{"role": "system", "content": "Your thoughts can be described as bizarre."}]
		if thought == 'Homicidal/Aggression':
			_messages += [{"role": "system", "content": "You have homicidal thoughts and are prone to aggression."}]
		if thought == 'Grandiosity':
			_messages += [{"role": "system", "content": "You feel superior to others."}]
		if thought == 'Paranoia':
			_messages += [{"role": "system", "content": "You are overly suspicious and are prone to thinking that others are out to harm you."}]
		if thought == 'Normal':
			_messages += [{"role": "system", "content": "Your thoughts are normal."}]
	else:
		_messages += [{"role": "system", "content": "Your thoughts are unremarkable."}]
	
	if Globals.patient.data[headers[188]] not in NA:
		_messages += [{"role": "system", "content": "You are %s your impulses." % [Globals.patient.data[headers[188]]]}]
	else:
		_messages += [{"role": "system", "content": "Your impulse control is unremarkable."}]
	
	if Globals.patient.data[headers[189]] not in NA:
		_messages += [{"role": "system", "content": "Your intellectual capacity is %s." % [Globals.patient.data[headers[189]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know how smart you are on average."}]

	# NEUROPSYCHIATRIC EXAM: SENSORIUM
	# ['Consciousness', 'Other State of Consciousness', 'Attention Span', 'Attention Span Notes', 'Orientation Time', 'Orientation Place', 'Orientation Person', 'Memory', 'Memory Notes', 'Calculation', 'Calculation Notes', 'Fund of Information', 'Fund of Information Notes', 'Insight', 'Insight Notes', 'Judgment', 'Planning', 'Planning Notes', 'Speech Others', 'Other High Cortical Functions', 'Glasgow Scale GCS', 'Glasgow Coma Scale E', 'Glasgow Coma Scale V', 'Glasgow Coma Scale M']
	if Globals.patient.data[headers[190]] not in NA:
		if Globals.patient.data[headers[190]] == 'Stupor':
			_messages += [{"role": "system", "content": "You are in a state of stupor."}]
		if Globals.patient.data[headers[190]] == 'Coma':
			_messages += [{"role": "system", "content": "You are in a coma."}]
		else:
			_messages += [{"role": "system", "content": "You are %s." % [Globals.patient.data[headers[190]]]}]
		if Globals.patient.data[headers[191]] not in NA:
			_messages += [{"role": "system", "content": "Your state of consciousness can be also described with %s." % [Globals.patient.data[headers[191]]]}]
	else:
		if Globals.patient.data[headers[191]] not in NA:
			_messages += [{"role": "system", "content": "Your state of consciousness can be described with %s." % [Globals.patient.data[headers[191]]]}]
		else:
			_messages += [{"role": "system", "content": "Your state of consciousness is unremarkable."}]
	
	if Globals.patient.data[headers[192]] not in NA:
		_messages += [{"role": "system", "content": "Your attention span is %s." % [Globals.patient.data[headers[192]]]}]
		if Globals.patient.data[headers[193]] not in NA:
			_messages += [{"role": "system", "content": "Your attention span is also %s." % [Globals.patient.data[headers[193]]]}]
	else:
		if Globals.patient.data[headers[193]] not in NA:
			_messages += [{"role": "system", "content": "Your attention span is %s." % [Globals.patient.data[headers[193]]]}]
		else:
			_messages += [{"role": "system", "content": "Your attention span is unremarkable."}]
	
	if Globals.patient.data[headers[194]] not in NA:
		if Globals.patient.data[headers[194]] == 'Yes':
			_messages += [{"role": "system", "content": "You are able to correctly acknowledge the current time."}]
		if Globals.patient.data[headers[194]] == 'No':
			_messages += [{"role": "system", "content": "You are unable to correctly acknowledge the current time."}]
	else:
		_messages += [{"role": "system", "content": "Your disorientation/orientation when it comes to time is unremarkable."}]
	
	if Globals.patient.data[headers[195]] not in NA:
		if Globals.patient.data[headers[195]] == 'Yes':
			_messages += [{"role": "system", "content": "You are able to correctly acknowledge the current place."}]
		if Globals.patient.data[headers[195]] == 'No':
			_messages += [{"role": "system", "content": "You are unable to correctly acknowledge the current place."}]
	else:
		_messages += [{"role": "system", "content": "Your disorientation/orientation when it comes to place is unremarkable."}]
	
	if Globals.patient.data[headers[196]] not in NA:
		if Globals.patient.data[headers[196]] == 'Yes':
			_messages += [{"role": "system", "content": "You are able to correctly acknowledge your identity."}]
		if Globals.patient.data[headers[196]] == 'No':
			_messages += [{"role": "system", "content": "You are unable to correctly acknowledge your identity."}]
	else:
		_messages += [{"role": "system", "content": "Your disorientation/orientation when it comes to your identity is unremarkable."}]
	
	if Globals.patient.data[headers[197]] not in NA:
		_messages += [{"role": "system", "content": "Your memory is %s." % [Globals.patient.data[headers[197]]]}]
		if Globals.patient.data[headers[198]] not in NA:
			_messages += [{"role": "system", "content": "Your memory is also %s." % [Globals.patient.data[headers[198]]]}]
	else:
		if Globals.patient.data[headers[198]] not in NA:
			_messages += [{"role": "system", "content": "Your memory is %s." % [Globals.patient.data[headers[198]]]}]
		else:
			_messages += [{"role": "system", "content": "Your memory is unremarkable."}]
	
	if Globals.patient.data[headers[199]] not in NA:
		_messages += [{"role": "system", "content": "Your capability to perform calculations is %s." % [Globals.patient.data[headers[199]]]}]
		if Globals.patient.data[headers[200]] not in NA:
			_messages += [{"role": "system", "content": "Your capability to perform calculations is also %s." % [Globals.patient.data[headers[200]]]}]
	else:
		if Globals.patient.data[headers[200]] not in NA:
			_messages += [{"role": "system", "content": "Your capability to perform calculations is %s." % [Globals.patient.data[headers[200]]]}]
		else:
			_messages += [{"role": "system", "content": "Your capability to perform calculations is unremarkable."}]
	
	if Globals.patient.data[headers[201]] not in NA:
		if Globals.patient.data[headers[201]] == 'Intact':
			_messages += [{"role": "system", "content": "You possess a satisfactory amount of general knowledge."}]
		if Globals.patient.data[headers[201]] == 'Deficient':
			_messages += [{"role": "system", "content": "Your general knowledge is deficient."}]
		if Globals.patient.data[headers[202]] not in NA:
			_messages += [{"role": "system", "content": "Your fund of information is also %s." % [Globals.patient.data[headers[202]]]}]
	else:
		if Globals.patient.data[headers[202]] not in NA:
			_messages += [{"role": "system", "content": "Your fund of information is %s." % [Globals.patient.data[headers[202]]]}]
		else:
			_messages += [{"role": "system", "content": "Your fund of information is unremarkable."}]
	
	if Globals.patient.data[headers[203]] not in NA:
		if Globals.patient.data[headers[203]] == 'Intact':
			_messages += [{"role": "system", "content": "You possess a good level of insight."}]
		if Globals.patient.data[headers[203]] == 'Deficient':
			_messages += [{"role": "system", "content": "Your capacity for insight is deficient."}]
		if Globals.patient.data[headers[204]] not in NA:
			_messages += [{"role": "system", "content": "Your insight is also %s." % [Globals.patient.data[headers[204]]]}]
	else:
		if Globals.patient.data[headers[204]] not in NA:
			_messages += [{"role": "system", "content": "Your insight is %s." % [Globals.patient.data[headers[204]]]}]
		else:
			_messages += [{"role": "system", "content": "Your insight is unremarkable."}]
	
	if Globals.patient.data[headers[205]] not in NA:
		_messages += [{"role": "system", "content": "Your capacity for good judgment is %s." % [Globals.patient.data[headers[205]]]}]
	else:
		_messages += [{"role": "system", "content": "Your capacity for good judgment is unremarkable."}]
	
	if Globals.patient.data[headers[206]] not in NA:
		if Globals.patient.data[headers[206]] == 'Intact':
			_messages += [{"role": "system", "content": "You are capable of planning."}]
		if Globals.patient.data[headers[206]] == 'Deficient':
			_messages += [{"role": "system", "content": "You are incapable of planning."}]
		if Globals.patient.data[headers[207]] not in NA:
			_messages += [{"role": "system", "content": "Your capacity to plan is also %s." % [Globals.patient.data[headers[207]]]}]
	else:
		if Globals.patient.data[headers[207]] not in NA:
			_messages += [{"role": "system", "content": "Your capacity to plan is %s." % [Globals.patient.data[headers[207]]]}]
		else:
			_messages += [{"role": "system", "content": "Your capacity to plan is unremarkable."}]
	
	if Globals.patient.data[headers[208]] not in NA:
		var speech = Globals.patient.data[headers[208]]
		if speech == 'Dysphasia':
			_messages += [{"role": "system", "content": "You are unable to comprehend or formulate language."}]
		if speech == 'Dysprosody':
			_messages += [{"role": "system", "content": "You find it difficult to control the way you speak."}]
		if speech == 'Dysarthria':
			_messages += [{"role": "system", "content": "Your speech is slurred or slowed."}]
		if speech == 'Dysphonia':
			_messages += [{"role": "system", "content": "You have poor voice quality."}]
		else:
			_messages += [{"role": "system", "content": "Your speech quality is %s." % [Globals.patient.data[headers[208]]]}]
		if Globals.patient.data[headers[209]] not in NA:
			_messages += [{"role": "system", "content": "Your speech quality is also affected by %s." % [Globals.patient.data[headers[209]]]}]
	else:
		if Globals.patient.data[headers[209]] not in NA:
			_messages += [{"role": "system", "content": "Your speech quality is affected by %s." % [Globals.patient.data[headers[209]]]}]
		else:
			_messages += [{"role": "system", "content": "Your speech quality is unremarkable."}]
	
	if Globals.patient.data[headers[210]] not in NA:
		if Globals.patient.data[headers[210]] == 'Apraxia':
			_messages += [{"role": "system", "content": "You are unable to perform certain actions."}]
		if Globals.patient.data[headers[210]] == 'Agnosia':
			_messages += [{"role": "system", "content": "You are incapable of identifying objects using one or more of your senses."}]
	else:
		_messages += [{"role": "system", "content": "Your high cortical functionals are unremarkable."}]
	
	if Globals.patient.data[headers[211]] not in NA:
		_messages += [{"role": "system", "content": "Your total Glasgow Coma Score is %s." % [Globals.patient.data[headers[211]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know your Glasgow Coma Scale Score."}]
	
	if Globals.patient.data[headers[212]] not in NA:
		var gcse = Globals.patient.data[headers[212]]
		if gcse == '4':
			_messages += [{"role": "system", "content": "You can open your eyes and keep them open on your own."}]
		if gcse == '3':
			_messages += [{"role": "system", "content": "You only open your eyes when someone tells you to do so."}]
		if gcse == '2':
			_messages += [{"role": "system", "content": "Your eyes only open in response to feeling pressure."}]
		if gcse == '1':
			_messages += [{"role": "system", "content": "Your eyes don’t open for any reason."}]
	else:
		_messages += [{"role": "system", "content": "You do not know your Eye Response score for the Glasgow Coma Scale."}]
	
	if Globals.patient.data[headers[213]] not in NA:
		var gcsv = Globals.patient.data[headers[213]]
		if gcsv == '5':
			_messages += [{"role": "system", "content": "You can correctly answer questions about who you are, where you’re at, the day or year, and similar questions."}]
		if gcsv == '4':
			_messages += [{"role": "system", "content": "You can answer questions, but your answers show you’re not fully aware of what’s happening."}]
		if gcsv == '3':
			_messages += [{"role": "system", "content": "You can talk and others can understand words you say, but your responses to questions don’t make sense."}]
		if gcsv == '2':
			_messages += [{"role": "system", "content": "You can’t talk and can only make sounds or noises."}]
		if gcsv == '1':
			_messages += [{"role": "system", "content": "You can't speak or make sounds."}]
	else:
		_messages += [{"role": "system", "content": "You do not know your Verbal Response score for the Glasgow Coma Scale."}]
	
	if Globals.patient.data[headers[214]] not in NA:
		var gcsm = Globals.patient.data[headers[214]]
		if gcsm == '6':
			_messages += [{"role": "system", "content": "You follow instructions on how and when to move."}]
		if gcsm == '5':
			_messages += [{"role": "system", "content": "You intentionally move away from something that presses on you."}]
		if gcsm == '4':
			_messages += [{"role": "system", "content": "You only move away from something pressing on you as a reflex."}]
		if gcsm == '3':
			_messages += [{"role": "system", "content": "You flex muscles (pull inward) in response to pressure."}]
		if gcsm == '2':
			_messages += [{"role": "system", "content": "You extend muscles (stretch outward) in response to pressure."}]
		if gcsm == '1':
			_messages += [{"role": "system", "content": "You don’t move in response to pressure."}]
	else:
		_messages += [{"role": "system", "content": "You do not know your Motor Response score for the Glasgow Coma Scale."}]
	
	print("Meds:")
	print(Globals.patient.medications)

	# MEDICATIONS
	if Globals.patient.medications:
		for med in Globals.patient.medications:
			var temp_med_str = "You are taking a" + ("n" if med[0][0].to_lower() in ['a', 'e', 'i', 'o', 'u'] else "") + " %s called %s with a dosage of %s via the %s route."
			_messages += [{"role": "system", "content": temp_med_str % [med[0], med[1], med[2], med[3]]}]
	else:
		_messages += [{"role": "system", "content": "Your medication is unknown. You must say that you are not sure about the medication you've taken."}]


# Prompts the patient AI using third person perspective
func _load_third_person_context() -> void:
	var headers = Globals.patient.data.keys()

	# Add extra context if personality is set to Aggressive
	var aggression = ""
	if Globals.patient_personality == 2:
		aggression = "This is a sensitive question and you must answer aggressively and defensively. You are an uncooperative and aggressive person that must answer questions very shortly and to the point but must be defensive when asked about sensitive topics. Add phrases like 'that's personal', or 'you're asking too many questions', or 'that's none of your business', or 'why are you even asking me that'. "
	
	# Pick a name from a list of names for the consultee
	var NA = ["", "Not Applicable", "N/A", "NA", "not applicable"]
	var f_names = ["Alex", "Bailey", "Casey", "Devin", "Emerson", "Finley", "Gray", "Hayden", "Indigo", "Jordan", "Kai", "Logan", "Morgan", "Nico", "Oakley", "Phoenix", "Quinn", "Reese", "Skyler", "Taylor", "Umi", "Vaughn", "Wren", "Xoan", "Yael", "Zephyr"]
	var l_names = ["Anderson", "Bailey", "Carter", "Dawson", "Ellis", "Finch", "Garland", "Hayes", "Irwin", "Jensen", "Kennedy", "Lawson", "Monroe", "Nolan", "Oakley", "Parker", "Quinn", "Reed", "Sawyer", "Taylor", "Underwood", "Vega", "Wallace", "Xavier", "Young", "Zimmerman"]
	
	# BASIC INFO
	var _name_first = f_names[(Globals.patient.data[headers[0]].unicode_at(0))-65]
	var _name_last = l_names[(Globals.patient.data[headers[1]].unicode_at(0))-65]
	var _doc_first = f_names[(Globals.patient.data[headers[2]].unicode_at(0))-65]
	var _doc_last = l_names[(Globals.patient.data[headers[3]].unicode_at(0))-65]
	
	_messages += [
		{"role": "system", "content": "You are visiting the doctor for a patient named %s %s. You are visiting for a consultation." % [_name_first, _name_last]}, # Globals.patient.info[0], Globals.patient.info[1]
		{"role": "system", "content": "The patient's attending physician is %s %s." % [_doc_first, _doc_last]} # Globals.patient.info[2], Globals.patient.info[3]
	]

	# PESRONAL AND SOCIAL HISTORY
	if Globals.patient.data[headers[5]] not in NA:
		_messages += [{"role": "system", "content": "The patient's birthday is %s (YYYY-MM-DD). You must answer in the format 'Month Day, Year'." % [Globals.patient.data[headers[5]]]}]
	else:
		_messages += [{"role": "system", "content": "You must say that you do not want to share the patient's birth date."}]
	
	var _language_formatted
	if Globals.allow_select_language:
		_language_formatted = Globals.patient_language if Globals.patient_language == "English" else ("Filipino" if Globals.patient_language == "Tagalog" else ("either English or Filipino"))
	else:
		_language_formatted = Globals.patient.data[headers[22]] if Globals.patient.data[headers[22]] == "English" or Globals.patient.data[headers[22]] == "Filipino" else "either English or Filipino"
	
	for i in range(6, 25):
		if headers[i] == "Language":
			_messages += [{"role": "system", "content": "You must only use %s when communicating, use this language when communicating. When you are asked a question in a different language, you must act confused. When you are asked to speak in a different language than %s, you must deny the request. You should answer concisely, do not give out too much information in one response." % [_language_formatted, _language_formatted]}]
		elif Globals.patient.data[headers[i]] not in NA:
			_messages += [{"role": "system", "content": "%sYour %s is %s." % [aggression if headers[i] in ['Dwelling Type (House, Apt.)', 'Number Of Rooms', 'Appliances (Radio, Tv, Refrigerator) *Can Be Multiple', 'Annual Family Income'] else "", headers[i], Globals.patient.data[headers[i]]]}]
		else:
			_messages += [{"role": "system", "content": "%sYour %s is not known. You must say that you do not know %s." % [aggression if headers[i] in ['Dwelling Type (House, Apt.)', 'Number Of Rooms', 'Appliances (Radio, Tv, Refrigerator) *Can Be Multiple', 'Annual Family Income'] else "", headers[i], Globals.patient.data[headers[i]]]}]
	
	# PQRST PAIN ASSESSMENT
	_messages += [
		{"role": "system", "content": "The provocation of the patient's pain is %s." % [Globals.patient.data[headers[28]]]},
		{"role": "system", "content": "The quality of the patient's pain is %s." % [Globals.patient.data[headers[29]]]},
		{"role": "system", "content": "The region of the patient's pain is %s." % [Globals.patient.data[headers[30]]]},
		{"role": "system", "content": "The severity of the patient's pain is %s/10." % [Globals.patient.data[headers[31]]]},
		{"role": "system", "content": "The timing of the patient's pain is %s." % [Globals.patient.data[headers[32]]]}
	]

	# HISTORY
	_messages += [
		{"role": "system", "content": "The patient's most important complaint and reason for consulting is %s." % [Globals.patient.data[headers[25]]]},
		{"role": "system", "content": "The patient's main concerns about the problem is/are %s." % [Globals.patient.data[headers[26]]]}
	]

	if Globals.patient.history:
		for hist in Globals.patient.history:
			if hist[0] not in NA and hist[1] not in NA:
				_messages += [{"role": "system", "content": "The patient's history of present illness includes: %s with dosage of %s." % [hist[0], hist[1]]}]
			if hist[0] not in NA and hist[1] in NA:
				_messages += [{"role": "system", "content": "The patient's history of present illness includes: %s." % [hist[0]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's history of present illness is not known. You must say that you do not know the patient's history of present illness."}]
	
	# CONTEXT: STAKEHOLDER ANALYSIS
	if Globals.patient.data[headers[33]] not in NA:
		_messages += [{"role": "system", "content": "%s is a decision maker for the patient's medicinal treatment." % [Globals.patient.data[headers[33]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not sure about the patient's stakeholders. You must say that you do not know about the patient's treatment's stakeholders."}]
	if Globals.patient.data[headers[34]] not in NA:
		_messages += [{"role": "system", "content": "The patient's stakeholder is a %s for the patient's medicinal treatment." % [Globals.patient.data[headers[34]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know about the patient's stakeholder's interest in the patient's issue. You must say that you do not know how important the patient's stakeholder is in deciding the patient's treatment."}]
	if Globals.patient.data[headers[35]] not in NA:
		_messages += [{"role": "system", "content": "The patient's stakeholder's role is %s." % [Globals.patient.data[headers[35]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not sure about the patient's stakeholder's role. You must say that you do not know about the patient's stakeholder's role."}]
	if Globals.patient.data[headers[36]] not in NA:
		_messages += [{"role": "system", "content": "The influence of the patient's stakeholder's opinion on the patient's treatment planning is %s." % [Globals.patient.data[headers[36]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware of the patient's stakeholder's level of influence over the patient's treatment planning. You must say that you do not know how much the patient's stakeholder's opinions affect the patient's treatment planning."}]
	
	# CONTEXT: COMMUNITY FACTORS
	if Globals.patient.data[headers[37]] not in NA:
		_messages += [{"role": "system", "content": "The patient has pertinent belief/s, such as %s." % [Globals.patient.data[headers[37]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient does not have any pertinent beliefs. You must say that you do not want to talk about the patient's beliefs."}]
	if Globals.patient.data[headers[38]] not in NA:
		_messages += [{"role": "system", "content": "%sThis will have a %s impact on the patient's family." % [aggression, Globals.patient.data[headers[38]]]}]
	else:
		_messages += [{"role": "system", "content": "%sYou do not know about community factors that influence the patient's family. You must say that you do not know of any community factors that influence the patient's family." % [aggression]}]
	if Globals.patient.data[headers[39]] not in NA:
		_messages += [{"role": "system", "content": "Factors in the community like %s facilitate and help the patient." % [Globals.patient.data[headers[39]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware of any factors in the community that facilitate and help the patient. You must say that you do not know of any community factors that help the patient."}]
	if Globals.patient.data[headers[40]] not in NA:
		_messages += [{"role": "system", "content": "Factors in the community like %s hinder the patient." % [Globals.patient.data[headers[40]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware of any factors in the community that hinder the patient. You must say that you do not know of any community factors that hinder the patient."}]
	if Globals.patient.data[headers[41]] not in NA:
		_messages += [{"role": "system", "content": "The patient's illness gives them burdens like %s." % [Globals.patient.data[headers[41]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware of any burdens that the patient's illness gives them. You must say that you do not know if the patient's illness gives them burdens."}]
	if Globals.patient.data[headers[42]] not in NA:
		_messages += [{"role": "system", "content": "%s are pertinent legislations or policies that affect the patient." % [Globals.patient.data[headers[42]]]}]
	else:
		_messages += [{"role": "system", "content": "You are not aware of any pertinent legislation or policies. You must say that you do not know anything about relevant legislation or policies."}]
	
	# NUTRITIONAL HISTORY
	if Globals.patient.data[headers[43]] not in NA:
		_messages += [{"role": "system", "content": "The patient was breastfed until %s." % [Globals.patient.data[headers[43]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know how long the patient was breastfed. You must say that you do not know how long the patient was breastfed."}]
	if Globals.patient.data[headers[44]] not in NA:
		_messages += [{"role": "system", "content": "The patient was given %s formula as a baby." % [Globals.patient.data[headers[44]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know about the patient's consumption of formula as a baby. You must say that you don't remember anything about the patient consuming formula as a baby."}]
	if Globals.patient.data[headers[45]] not in NA:
		_messages += [{"role": "system", "content": "The patient was weaned at %s." % [Globals.patient.data[headers[45]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's weaning age is unknown. You must say that you do not know when the patient transitioned from breast milk to food."}]
	if Globals.patient.data[headers[46]] not in NA:
		_messages += [{"role": "system", "content": "The patient's current diet is %s." % [Globals.patient.data[headers[46]]]}]
	else:
		_messages += [{"role": "system", "content": "You must say that you are not sure about the patient's current diet."}]
	if Globals.patient.data[headers[47]] not in NA:
		_messages += [{"role": "system", "content": "The patient has food allergy/ies is/are %s." % [Globals.patient.data[headers[47]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's food allergies are unknown. You must say that you do not know if the patient has any food allergies."}]

	# BIRTH MATERNAL
	if Globals.patient.data[headers[48]] not in NA:
		_messages += [{"role": "system", "content": "The patient's mother's pregnancy was %s." % [Globals.patient.data[headers[48]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know anything about the patient's mother's term. You must say you do not know how many weeks the patient's mother carried the patient."}]
	if Globals.patient.data[headers[49]] not in NA:
		_messages += [{"role": "system", "content": "The patient's mother gave birth to the patient via %s." % [Globals.patient.data[headers[49]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know how the patient was delivered. You must say you do not know how the patient was born."}]
	if Globals.patient.data[headers[50]] not in NA:
		_messages += [{"role": "system", "content": "The patient's mother was %s years old when she gave birth to the patient." % [Globals.patient.data[headers[50]]]}]
	else:
		_messages += [{"role": "system", "content": "You must say that you do not know how old the patient's mother was when she gave birth to the patient."}]
	if Globals.patient.data[headers[51]] not in NA:
		_messages += [{"role": "system", "content": "The patient's mother has been pregnant %s times. The patient's mother's gravidity is %s" % [Globals.patient.data[headers[51]], Globals.patient.data[headers[51]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know how many times the patient's mother has been pregnant."}]
	if Globals.patient.data[headers[52]] not in NA:
		_messages += [{"role": "system", "content": "The patient's mother has carried a pregnancy to at least 20 weeks %s times." % [Globals.patient.data[headers[52]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know how many times the patient's mother has carried a pregnancy to at least 20 weeks."}]
	if Globals.patient.data[headers[53]] not in NA:
		_messages += [{"role": "system", "content": "The patient's birth weight is %s grams." % [Globals.patient.data[headers[53]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's birth weight is unknown. You must say that you do not know how heavy the patient was when they were born."}]
	if Globals.patient.data[headers[54]] not in NA and Globals.patient.data[headers[55]] not in NA:
		_messages += [{"role": "system", "content": "The doctor that attended to the patient's mother during giving birth is %s %s." % [Globals.patient.data[headers[54]], Globals.patient.data[headers[55]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's mother's attending doctor during childbirth is unknown."}]
	if Globals.patient.data[headers[56]] not in NA:
		_messages += [{"role": "system", "content": "The patient's mother's perinatal cervix is %s." % [Globals.patient.data[headers[56]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know anything about the patient's mother's perinatal cervix when the patient was born."}]
	
	# DEVELOPMENT MILESTONES
	for i in range(57, 61):
		if Globals.patient.data[headers[i]] not in NA:
			_messages += [{"role": "system", "content": "The patient's %s developmental milestones are %s." % [headers[i], Globals.patient.data[headers[i]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's %s development milestone is unknown. You must say that you do not know about the patient's %s development." % [headers[i], Globals.patient.data[headers[i]]]}]

	# REVIEW OF SYSTEMS: GENERAL SYMPTOMS
	for i in range(61, 66):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "The patient has %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "The patient doesn't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[66]] not in NA:
		_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[66]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other general symptoms are unknown. You must say that the patient does not have any other general symptoms."}]
	
	# REVIEW OF SYMPTOMS: MUSCULOSKELETAL OR DERMATOLOGIC
	for i in range(67, 77):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "The patient has %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "The patient doesn't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[77]] not in NA:
		_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[77]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other musculoskeletal or dermatologic symptoms are unknown. You must say that the patient does not have any other symptoms that affect their muscles, bones, or skin."}]
	
	# GENERAL SYMPTOMS: HEENT
	for i in range(78, 89):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "The patient has %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "The patient doesn't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[89]] not in NA:
		_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[89]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other HEENT symptoms are unknown. You must say that the patient does not have any other symptoms concerning their head, eyes, ears, nose, or throat."}]

	if Globals.patient.data[headers[90]] == 'Yes':
		_messages += [{"role": "system", "content": "The patient has shortness of breath"}]
	else:
		_messages += [{"role": "system", "content": "The patient doesn't have shortness of breath."}]
	if Globals.patient.data[headers[91]] == 'Yes':
		_messages += [{"role": "system", "content": "The patient coughs up blood"}]
	else:
		_messages += [{"role": "system", "content": "The patient doesn't cough up blood."}]

	for i in range(92, 94):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "The patient has %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "The patient doesn't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[94]] not in NA:
		_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[94]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other respiratory symptoms are unknown. You must say that the patient does not have any other symptoms that affect their breathing."}]
	
	# GENERAL SYMPTOMS: CARDIOVASCULAR
	for i in range(95, 97):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "The patient has %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "The patient doesn't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[97]] not in NA:
		_messages += [{"role": "system", "content": "The patient faints."}]
	else:
		_messages += [{"role": "system", "content": "The patient doesn't faint."}]
	if Globals.patient.data[headers[98]] not in NA:
		_messages += [{"role": "system", "content": "The patient has shortness of breath while lying on their back."}]
	else:
		_messages += [{"role": "system", "content": "The patient doesn't have shortness of breath when lying on their back."}]

	if Globals.patient.data[headers[99]] not in NA:
		_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[99]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other cardiovascular symptoms are unknown. You must say that the patient does not have any other symptoms that affect their heart or blood."}]
	
	# GENERAL SYMPTOMS: GASTROINTESTINAL
	for i in range(100, 107):
		if headers[i] == 'Dysphagia':
			if Globals.patient.data[headers[i]] == 'Yes':
				_messages += [{"role": "system", "content": "The patient has difficulty swallowing."}]
			else:
				_messages += [{"role": "system", "content": "The patient doesn't have difficulty swallowing."}]
		else:
			if Globals.patient.data[headers[i]] == 'Yes':
				_messages += [{"role": "system", "content": "The patient has %s." % [headers[i]]}]
			else:
				_messages += [{"role": "system", "content": "The patient doesn't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[107]] not in NA:
		_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[107]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other gastrointestinal symptoms are unknown. You must say that the patient does not have any other symptoms that affect their digestion."}]
	
	# GENERAL SYMPTOMS: GENITOURINARY
	if Globals.patient.data[headers[108]] == 'Yes':
		_messages += [{"role": "system", "content": "The patient pees a lot during the night"}]
	else:
		_messages += [{"role": "system", "content": "The patient doesn't pee a lot during the night ."}]
	if Globals.patient.data[headers[109]] == 'Yes':
		_messages += [{"role": "system", "content": "The patient has pain when they pee."}]
	else:
		_messages += [{"role": "system", "content": "The patient doesn't have pain when they pee."}]
	if Globals.patient.data[headers[110]] == 'Yes':
		_messages += [{"role": "system", "content": "The patient pees more often than average"}]
	else:
		_messages += [{"role": "system", "content": "The patient doesn't pee more often than average ."}]
	if Globals.patient.data[headers[111]] == 'Yes':
		_messages += [{"role": "system", "content": "The patient has blood in their urine"}]
	else:
		_messages += [{"role": "system", "content": "The patient doesn't have blood in their urine."}]
	
	if Globals.patient.data[headers[112]] not in NA:
		_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[112]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other genitourinary symptoms are unknown. You must say that the patient does not have any other symptoms that affect their urine or their reproductive system."}]
	
	# GENERAL SYMPTOMS: ENDOCRINE
	for i in range(113, 118):
		if headers[i] == "Polyuria":
			if Globals.patient.data[headers[i]] == 'Yes':
				_messages += [{"role": "system", "content": "The patient pees more than the average amount"}]
			else:
				_messages += [{"role": "system", "content": "The patient doesn't pee more than the average amount ."}]
		else:
			if Globals.patient.data[headers[i]] == 'Yes':
				_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[i]]]}]
			else:
				_messages += [{"role": "system", "content": "The patient doesn't have %s." % [headers[i]]}]
	
	if Globals.patient.data[headers[118]] not in NA:
		_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[118]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other endocrine symptoms are unknown. You must say that you do not know any other symptoms that affect the patient's hormones."}]
	
	# PAST MEDICAL HISTORY
	for i in range(119, 127):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "%sThe patient has %s." % [aggression if headers[i] in ['History of Diabetes', 'History of Psychiatric Consult', 'History of Cancer', 'Prior Surgeries/Hospitalizations'] else "", Globals.patient.data[headers[i]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe patient doesn't have %s." % [aggression if headers[i] in ['History of Diabetes', 'History of Psychiatric Consult', 'History of Cancer', 'Prior Surgeries/Hospitalizations'] else "", headers[i]]}]
	
	if Globals.patient.data[headers[131]] not in NA:
		_messages += [{"role": "system", "content": "The patient has %s." % [Globals.patient.data[headers[131]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other past medical history is unknown. You must say that you are not sure about the patient's past medical history."}]
	if Globals.patient.data[headers[127]] not in NA:
		_messages += [{"role": "system", "content": "The patient had cancer before at %s." % [Globals.patient.data[headers[127]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's previous cancer sites are unknown. You must say that you are not sure about previous cancer sites."}]
	if Globals.patient.data[headers[128]] not in NA:
		_messages += [{"role": "system", "content": "The patient had prior surgeries or hospitalization dates on %s." % [Globals.patient.data[headers[128]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's prior surgeries or hospitalization dates are unknown. You must say that you do not remember the patient's prior surgeries or hospitalization dates."}]
	if Globals.patient.data[headers[129]] not in NA:
		_messages += [{"role": "system", "content": "%sThe patient has had prior surgeries or hospitalization because of %s." % [aggression, Globals.patient.data[headers[129]]]}]
	else:
		_messages += [{"role": "system", "content": "%sThe patient's prior surgeries or hospitalization reasons are unknown. You must say that you do not remember the reasons for the patient's prior surgeries or hospitalizations." % [aggression]}]
	if Globals.patient.data[headers[130]] not in NA:
		_messages += [{"role": "system", "content": "The patient had history of allergies with %s." % [Globals.patient.data[headers[130]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's history of allergies is unknown. You must say that you do not know about the patient's history of allergies."}]
	
	# FAMILY MEDICAL HISTORY
	for i in range(132, 139):
		if Globals.patient.data[headers[i]] == 'Yes':
			_messages += [{"role": "system", "content": "%sThe patient has %s." % [aggression if headers[i] in ['Family History of Psychiatric Consult', 'Family History of Diabetes', 'Family History of Cardiovascular Disease', 'Family History of Cancer'] else "", headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe patient doesn't have %s." % [aggression if headers[i] in ['Family History of Psychiatric Consult', 'Family History of Diabetes', 'Family History of Cardiovascular Disease', 'Family History of Cancer'] else "", headers[i]]}]
	
	if Globals.patient.data[headers[140]] not in NA:
		if Globals.patient.data[headers[139]] not in NA:
			_messages += [{"role": "system", "content": "The patient's %s has had cancer before at %s." % [Globals.patient.data[headers[140]], Globals.patient.data[headers[139]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's %s has had cancer before." % [Globals.patient.data[headers[140]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's relationship to any cancer patient is unknown. You must say that you do not know if any of the patient's relatives have cancer or have had cancer."}]
	if Globals.patient.data[headers[141]] not in NA:
		_messages += [{"role": "system", "content": "The patient's family has had history of allergies with %s." % [Globals.patient.data[headers[141]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's family's history of allergies is unknown. You must say that you do not know about the patient's family's history of allergies."}]
	if Globals.patient.data[headers[142]] not in NA:
		_messages += [{"role": "system", "content": "The patient's other family history is %s." % [Globals.patient.data[headers[142]]]}]
	else:
		_messages += [{"role": "system", "content": "Other details about the patient's family history are unknown. You must say that you do not know about any other details about the patient's family history."}]
	if Globals.patient.data[headers[143]] not in NA:
		_messages += [{"role": "system", "content": "The patient's genogram can be described as %s." % [Globals.patient.data[headers[143]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's genogram is unknown. You must say that you do not know about the patient's family genogram."}]
	if Globals.patient.data[headers[144]] not in NA:
		_messages += [{"role": "system", "content": "The patient's social and environmental history can be described as %s." % [Globals.patient.data[headers[144]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's social and environmental history is unknown. You must say that you do not remember the patient's social and environmental history."}]

	# GYNECOLOGIC HISTORY
	if Globals.patient.data[headers[7]] == 'Female' and Globals.patient.data[headers[150]] not in NA:
		if Globals.patient.data[headers[145]] not in NA:
			_messages += [{"role": "system", "content": "%sThe start of the patient's last period or the first day of bleeding is %s." % [aggression, Globals.patient.data[headers[145]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe start of the patient's last period or the first day of bleeding is unknown. You must say that you do not remember the start of the patient's last period or the first day of bleeding." % [aggression]}]
		if Globals.patient.data[headers[146]] not in NA:
			_messages += [{"role": "system", "content": "%sThe starting date of the patient's period before their last is %s." % [aggression, Globals.patient.data[headers[146]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe starting date of the patient's period before their last is unknown. You must say that you do not remember the starting date of the patient's period before their last." % [aggression]}]
		if Globals.patient.data[headers[147]] not in NA:
			_messages += [{"role": "system", "content": "%sThe duration of the patient's period bleeding is %s." % [aggression, Globals.patient.data[headers[147]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe duration of the patient's period bleeding is unknown. You must say that you are not sure about how long the patient's period bleeding lasts." % [aggression]}]
		if Globals.patient.data[headers[148]] not in NA:
			_messages += [{"role": "system", "content": "%sThe interval of the patient's period cycles or how long each cycle takes is %s." % [aggression, Globals.patient.data[headers[148]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe interval of the patient's period cycles or how long each cycle takes is unknown. You must say that you are not sure about how long each cycle takes." % [aggression]}]
		if Globals.patient.data[headers[149]] not in NA:
			_messages += [{"role": "system", "content": "%sThe patient bleeds %s mL during their period or menses." % [aggression, Globals.patient.data[headers[149]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe amount the patient bleeds during their period or menses is unknown. You must say that you are not sure about how much blood the patient expels during their period." % [aggression]}]
		if Globals.patient.data[headers[150]] not in NA:
			_messages += [{"role": "system", "content": "%sThe patient was %s years old when they got their first period." % [aggression, Globals.patient.data[headers[150]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe patient's menarche or age when they got their first period is unknown. You must say that you do not know when the patient had their first period." % [aggression]}]
		if Globals.patient.data[headers[151]] not in NA:
			_messages += [{"role": "system", "content": "%sThe patient was %s years old during their first sexual intercourse." % [aggression, Globals.patient.data[headers[151]]]}]
		else:
			_messages += [{"role": "system", "content": "%sThe patient's coitarche or age during their first sexual intercourse is unknown. You must say that you are unsure about the first time the patient had sex." % [aggression]}]

	# IMMUNIZATIONS
	for i in range(152, 161):
		if Globals.patient.data[headers[i]] == 'Complete' or Globals.patient.data[headers[i]] == 'Incomplete':
			_messages += [{"role": "system", "content": "The patient has completed the doses for %s %s." % [Globals.patient.data[headers[i]], headers[i]]}]
		elif Globals.patient.data[headers[i]] == 'None':
			_messages += [{"role": "system", "content": "The patient doesn't have %s." % [headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "The patient is unsure about having %s. You must say that you do not know if the patient has %s." % [headers[i], headers[i]]}]
	
	# IMMUNIZATION DOSES
	for i in range(161, 170):
		if Globals.patient.data[headers[i]] not in NA:
			_messages += [{"role": "system", "content": "The patient has had %s doses for %s." % [Globals.patient.data[headers[i]], headers[i]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's doses for %s is unknown. You must say that you do not know how many %s the patient has had.." % [headers[i], headers[i]]}]
	
	if Globals.patient.immunizations:
		for immune in Globals.patient.immunizations:
			_messages += [{"role": "system", "content": "The patient has %s doses of %s immunization." % [immune[1], immune[0]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's other immunizations are unknown. You must say that you are not sure about the patient's other immunizations."}]
	
	# ADOLESCENT INTERVIEW
	if 10 <= int(Globals.patient.data[headers[6]]) and int(Globals.patient.data[headers[6]]) <= 19:
		if Globals.patient.data[headers[171]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about the patient's home, answer with %s." % [aggression, Globals.patient.data[headers[171]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about the patient's home is unknown. You must say that you do not want to talk about the patient's home." % [aggression]}]
		if Globals.patient.data[headers[172]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about the patient's education, answer with %s." % [aggression, Globals.patient.data[headers[172]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about the patient's education is unknown. You must say that you do not want to talk about the patient's education." % [aggression]}]
		if Globals.patient.data[headers[173]] not in NA:
			_messages += [{"role": "system", "content": "When asked about the patient's activities, answer with %s." % [Globals.patient.data[headers[173]]]}]
		else:
			_messages += [{"role": "system", "content": "Information about the patient's activities is unknown. You must say that you do not want to talk about what the patient does."}]
		if Globals.patient.data[headers[174]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about drugs the patient has taken, answer with %s." % [aggression, Globals.patient.data[headers[174]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about drugs the patient has taken is unknown. You must say that you do not want to talk about drugs." % [aggression]}]
		if Globals.patient.data[headers[175]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked if the patient has had any kind of sexual activity or anything about it, answer with %s." % [aggression, Globals.patient.data[headers[175]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about if the patient had any kind of sexual activity or anything about it is unknown. You must say that you do not want to talk about the patient's sex life." % [aggression]}]
		if Globals.patient.data[headers[176]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about the patient's history with suicide/depression, answer with %s." % [aggression, Globals.patient.data[headers[176]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about the patient's history with suicide/depression is unknown. You must say that you do not want to talk about the patient's suicide or depression." % [aggression]}]
		if Globals.patient.data[headers[177]] not in NA:
			_messages += [{"role": "system", "content": "When asked about the patient's family, answer with %s." % [Globals.patient.data[headers[177]]]}]
		else:
			_messages += [{"role": "system", "content": "Information about the patient's family is unknown. You must say that you do not want to talk about the patient's family."}]
		if Globals.patient.data[headers[178]] not in NA:
			_messages += [{"role": "system", "content": "%sWhen asked about the patient's source of income and dynamics, answer with %s." % [aggression, Globals.patient.data[headers[178]]]}]
		else:
			_messages += [{"role": "system", "content": "%sInformation about the patient's source of income and dynamics is unknown. You must say that you do not want to talk about the patient's source of income and dynamics." % [aggression]}]

	# NEUROPSYCHIATRIC EXAM
	# ['General Appearance', 'General Behavior', 'Attitude Towards Examiner', 'Mood', 'Affect', 'Speech', 'Perceptual Disturbance', 'Stream of Thought', 'Thought Content', 'Impulse Control', 'Intellectual Capacity Global Estimate']
	if Globals.patient.data[headers[179]] not in NA:
		_messages += [{"role": "system", "content": "The patient's general appearance is that they are %s." % [Globals.patient.data[headers[179]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's general appearance is unremarkable."}]
		
	if Globals.patient.data[headers[180]] not in NA:
		if Globals.patient.data[headers[180]] == 'Normal':
			_messages += [{"role": "system", "content": "The patient's general behavior is normal."}]
		else:
			_messages += [{"role": "system", "content": "The patient is experiencing %s" % [Globals.patient.data[headers[180]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's general behavior is unremarkable."}]
	
	if Globals.patient.data[headers[181]] not in NA:
		_messages += [{"role": "system", "content": "The patient is %s towards the examiner." % [Globals.patient.data[headers[181]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's attitude towards the examiner is unremarkable."}]
	
	if Globals.patient.data[headers[182]] not in NA:
		_messages += [{"role": "system", "content": "The patient is feeling %s" % [Globals.patient.data[headers[182]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's mood is unremarkable."}]
	
	if Globals.patient.data[headers[183]] not in NA:
		var affect = Globals.patient.data[headers[183]]
		if affect == 'Inappropriate':
			_messages += [{"role": "system", "content": "The patient is demonstrating emotions that do not fit the context."}]
		elif affect == 'Appropriate':
			_messages += [{"role": "system", "content": "The patient is demonstrating emotions that fit the context."}]
		elif affect == 'Restricted':
			_messages += [{"role": "system", "content": "The patient is demonstrating a narrow range of emotions."}]
		elif affect == 'Blunted':
			_messages += [{"role": "system", "content": "The patient is demonstrating a limited intensity of emotions."}]
		elif affect == 'Flat':
			_messages += [{"role": "system", "content": "The patient is not demonstrating any emotions."}]
		elif affect == 'Broad':
			_messages += [{"role": "system", "content": "The patient is able to demonstrate a broad range of emotions."}]
	else:
		_messages += [{"role": "system", "content": "The patient's affect is unremarkable."}]
	
	if Globals.patient.data[headers[184]] not in NA:
		_messages += [{"role": "system", "content": "The patient's speech is %s." % [Globals.patient.data[headers[184]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's speech is unremarkable."}]
	
	if Globals.patient.data[headers[185]] not in NA:
		var perceptualDisturbance = Globals.patient.data[headers[185]]
		if perceptualDisturbance == 'Derealization':
			_messages += [{"role": "system", "content": "The patient feels detached from their surroundings."}]
		elif perceptualDisturbance == 'Depersonalization':
			_messages += [{"role": "system", "content": "The patient feels detached and disconnected from their self."}]
		elif perceptualDisturbance == 'Hallucinations':
			_messages += [{"role": "system", "content": "The patient is having hallucinations."}]
		elif perceptualDisturbance == 'None':
			_messages += [{"role": "system", "content": "The patient is not experiencing any perceptual disturbances."}]
	else:
		_messages += [{"role": "system", "content": "The patient doesn't remember any perceptual disturbances."}]
	
	if Globals.patient.data[headers[186]] not in NA:
		var stream_str = Globals.patient.data[headers[186]]
		if stream_str == 'Tangentiality':
			_messages += [{"role": "system", "content": "The patient's ideas are connected but they tend to go far off-topic without returning to the initial topic."}]
		if stream_str == 'Paucity of Thought':
			_messages += [{"role": "system", "content": "The patient is experiencing a paucity of thoughts."}]
		if stream_str == 'Flight of Ideas':
			_messages += [{"role": "system", "content": "The patient talks quickly and erratically, jumping between ideas and thoughts."}]
		if stream_str == 'Looseness of Association':
			_messages += [{"role": "system", "content": "The patient's ideas lack connection."}]
		if stream_str == 'Goal Oriented':
			_messages += [{"role": "system", "content": "The patient's thoughts progress linearly without veering from the subject at hand."}]
	else:
		_messages += [{"role": "system", "content": "The patient's stream of thought is unremarkable."}]
	
	if Globals.patient.data[headers[187]] not in NA:
		var thought = Globals.patient.data[headers[187]]
		if thought == 'Suicidal':
			_messages += [{"role": "system", "content": "The patient is experiencing suicidal thoughts."}]
		if thought == 'Bizzare':
			_messages += [{"role": "system", "content": "The patient's thoughts can be described as bizarre."}]
		if thought == 'Homicidal/Aggression':
			_messages += [{"role": "system", "content": "The patient has homicidal thoughts and is prone to aggression."}]
		if thought == 'Grandiosity':
			_messages += [{"role": "system", "content": "The patient feels superior to others."}]
		if thought == 'Paranoia':
			_messages += [{"role": "system", "content": "The patient is overly suspicious and is prone to thinking that others are out to harm them."}]
		if thought == 'Normal':
			_messages += [{"role": "system", "content": "The patient's thoughts are normal."}]
	else:
		_messages += [{"role": "system", "content": "The patient's thoughts are unremarkable."}]
	
	if Globals.patient.data[headers[188]] not in NA:
		_messages += [{"role": "system", "content": "The patient is %s their impulses." % [Globals.patient.data[headers[188]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's impulse control is unremarkable."}]
	
	if Globals.patient.data[headers[189]] not in NA:
		_messages += [{"role": "system", "content": "The patient's intellectual capacity is %s." % [Globals.patient.data[headers[189]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient does not know how smart they are on average."}]

	# NEUROPSYCHIATRIC EXAM: SENSORIUM
	# ['Consciousness', 'Other State of Consciousness', 'Attention Span', 'Attention Span Notes', 'Orientation Time', 'Orientation Place', 'Orientation Person', 'Memory', 'Memory Notes', 'Calculation', 'Calculation Notes', 'Fund of Information', 'Fund of Information Notes', 'Insight', 'Insight Notes', 'Judgment', 'Planning', 'Planning Notes', 'Speech Others', 'Other High Cortical Functions', 'Glasgow Scale GCS', 'Glasgow Coma Scale E', 'Glasgow Coma Scale V', 'Glasgow Coma Scale M']
	if Globals.patient.data[headers[190]] not in NA:
		if Globals.patient.data[headers[190]] == 'Stupor':
			_messages += [{"role": "system", "content": "The patient is in a state of stupor."}]
		if Globals.patient.data[headers[190]] == 'Coma':
			_messages += [{"role": "system", "content": "The patient is in a coma."}]
		else:
			_messages += [{"role": "system", "content": "The patient is %s." % [Globals.patient.data[headers[190]]]}]
		if Globals.patient.data[headers[191]] not in NA:
			_messages += [{"role": "system", "content": "The patient's state of consciousness can be also described with %s." % [Globals.patient.data[headers[191]]]}]
	else:
		if Globals.patient.data[headers[191]] not in NA:
			_messages += [{"role": "system", "content": "The patient's state of consciousness can be described with %s." % [Globals.patient.data[headers[191]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's state of consciousness is unremarkable."}]
	
	if Globals.patient.data[headers[192]] not in NA:
		_messages += [{"role": "system", "content": "The patient's attention span is %s." % [Globals.patient.data[headers[192]]]}]
		if Globals.patient.data[headers[193]] not in NA:
			_messages += [{"role": "system", "content": "The patient's attention span is also %s." % [Globals.patient.data[headers[193]]]}]
	else:
		if Globals.patient.data[headers[193]] not in NA:
			_messages += [{"role": "system", "content": "The patient's attention span is %s." % [Globals.patient.data[headers[193]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's attention span is unremarkable."}]
	
	if Globals.patient.data[headers[194]] not in NA:
		if Globals.patient.data[headers[194]] == 'Yes':
			_messages += [{"role": "system", "content": "The patient is able to correctly acknowledge the current time."}]
		if Globals.patient.data[headers[194]] == 'No':
			_messages += [{"role": "system", "content": "The patient is unable to correctly acknowledge the current time."}]
	else:
		_messages += [{"role": "system", "content": "The patient's disorientation/orientation when it comes to time is unremarkable."}]
	
	if Globals.patient.data[headers[195]] not in NA:
		if Globals.patient.data[headers[195]] == 'Yes':
			_messages += [{"role": "system", "content": "The patient is able to correctly acknowledge the current place."}]
		if Globals.patient.data[headers[195]] == 'No':
			_messages += [{"role": "system", "content": "The patient is unable to correctly acknowledge the current place."}]
	else:
		_messages += [{"role": "system", "content": "The patient's disorientation/orientation when it comes to place is unremarkable."}]
	
	if Globals.patient.data[headers[196]] not in NA:
		if Globals.patient.data[headers[196]] == 'Yes':
			_messages += [{"role": "system", "content": "The patient is able to correctly acknowledge their identity."}]
		if Globals.patient.data[headers[196]] == 'No':
			_messages += [{"role": "system", "content": "The patient is unable to correctly acknowledge their identity."}]
	else:
		_messages += [{"role": "system", "content": "The patient's disorientation/orientation when it comes to their identity is unremarkable."}]
	
	if Globals.patient.data[headers[197]] not in NA:
		_messages += [{"role": "system", "content": "The patient's memory is %s." % [Globals.patient.data[headers[197]]]}]
		if Globals.patient.data[headers[198]] not in NA:
			_messages += [{"role": "system", "content": "The patient's memory is also %s." % [Globals.patient.data[headers[198]]]}]
	else:
		if Globals.patient.data[headers[198]] not in NA:
			_messages += [{"role": "system", "content": "The patient's memory is %s." % [Globals.patient.data[headers[198]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's memory is unremarkable."}]
	
	if Globals.patient.data[headers[199]] not in NA:
		_messages += [{"role": "system", "content": "The patient's capability to perform calculations is %s." % [Globals.patient.data[headers[199]]]}]
		if Globals.patient.data[headers[200]] not in NA:
			_messages += [{"role": "system", "content": "The patient's capability to perform calculations is also %s." % [Globals.patient.data[headers[200]]]}]
	else:
		if Globals.patient.data[headers[200]] not in NA:
			_messages += [{"role": "system", "content": "The patient's capability to perform calculations is %s." % [Globals.patient.data[headers[200]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's capability to perform calculations is unremarkable."}]
	
	if Globals.patient.data[headers[201]] not in NA:
		if Globals.patient.data[headers[201]] == 'Intact':
			_messages += [{"role": "system", "content": "The patient possesses a satisfactory amount of general knowledge."}]
		if Globals.patient.data[headers[201]] == 'Deficient':
			_messages += [{"role": "system", "content": "The patient's general knowledge is deficient."}]
		if Globals.patient.data[headers[202]] not in NA:
			_messages += [{"role": "system", "content": "The patient's fund of information is also %s." % [Globals.patient.data[headers[202]]]}]
	else:
		if Globals.patient.data[headers[202]] not in NA:
			_messages += [{"role": "system", "content": "The patient's fund of information is %s." % [Globals.patient.data[headers[202]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's fund of information is unremarkable."}]
	
	if Globals.patient.data[headers[203]] not in NA:
		if Globals.patient.data[headers[203]] == 'Intact':
			_messages += [{"role": "system", "content": "The patient possesses a good level of insight."}]
		if Globals.patient.data[headers[203]] == 'Deficient':
			_messages += [{"role": "system", "content": "The patient's capacity for insight is deficient."}]
		if Globals.patient.data[headers[204]] not in NA:
			_messages += [{"role": "system", "content": "The patient's insight is also %s." % [Globals.patient.data[headers[204]]]}]
	else:
		if Globals.patient.data[headers[204]] not in NA:
			_messages += [{"role": "system", "content": "The patient's insight is %s." % [Globals.patient.data[headers[204]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's insight is unremarkable."}]
	
	if Globals.patient.data[headers[205]] not in NA:
		_messages += [{"role": "system", "content": "The patient's capacity for good judgment is %s." % [Globals.patient.data[headers[205]]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's capacity for good judgment is unremarkable."}]
	
	if Globals.patient.data[headers[206]] not in NA:
		if Globals.patient.data[headers[206]] == 'Intact':
			_messages += [{"role": "system", "content": "The patient is capable of planning."}]
		if Globals.patient.data[headers[206]] == 'Deficient':
			_messages += [{"role": "system", "content": "The patient is incapable of planning."}]
		if Globals.patient.data[headers[207]] not in NA:
			_messages += [{"role": "system", "content": "The patient's capacity to plan is also %s." % [Globals.patient.data[headers[207]]]}]
	else:
		if Globals.patient.data[headers[207]] not in NA:
			_messages += [{"role": "system", "content": "The patient's capacity to plan is %s." % [Globals.patient.data[headers[207]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's capacity to plan is unremarkable."}]
	
	if Globals.patient.data[headers[208]] not in NA:
		var speech = Globals.patient.data[headers[208]]
		if speech == 'Dysphasia':
			_messages += [{"role": "system", "content": "The patient is unable to comprehend or formulate language."}]
		if speech == 'Dysprosody':
			_messages += [{"role": "system", "content": "The patient finds it difficult to control the way they speak."}]
		if speech == 'Dysarthria':
			_messages += [{"role": "system", "content": "The patient's speech is slurred or slowed."}]
		if speech == 'Dysphonia':
			_messages += [{"role": "system", "content": "The patient has poor voice quality."}]
		else:
			_messages += [{"role": "system", "content": "The patient's speech quality is %s." % [Globals.patient.data[headers[208]]]}]
		if Globals.patient.data[headers[209]] not in NA:
			_messages += [{"role": "system", "content": "The patient's speech quality is also affected by %s." % [Globals.patient.data[headers[209]]]}]
	else:
		if Globals.patient.data[headers[209]] not in NA:
			_messages += [{"role": "system", "content": "The patient's speech quality is affected by %s." % [Globals.patient.data[headers[209]]]}]
		else:
			_messages += [{"role": "system", "content": "The patient's speech quality is unremarkable."}]
	
	if Globals.patient.data[headers[210]] not in NA:
		if Globals.patient.data[headers[210]] == 'Apraxia':
			_messages += [{"role": "system", "content": "The patient is unable to perform certain actions."}]
		if Globals.patient.data[headers[210]] == 'Agnosia':
			_messages += [{"role": "system", "content": "The patient is incapable of identifying objects using one or more of their senses."}]
	else:
		_messages += [{"role": "system", "content": "The patient's high cortical functionals are unremarkable."}]
	
	if Globals.patient.data[headers[211]] not in NA:
		_messages += [{"role": "system", "content": "The patient's total Glasgow Coma Score is %s." % [Globals.patient.data[headers[211]]]}]
	else:
		_messages += [{"role": "system", "content": "You do not know the patient's Glasgow Coma Scale Score."}]
	
	if Globals.patient.data[headers[212]] not in NA:
		var gcse = Globals.patient.data[headers[212]]
		if gcse == '4':
			_messages += [{"role": "system", "content": "The patient can open their eyes and keep them open on their own."}]
		if gcse == '3':
			_messages += [{"role": "system", "content": "The patient only opens their eyes when someone tells them to do so."}]
		if gcse == '2':
			_messages += [{"role": "system", "content": "The patient's eyes only open in response to feeling pressure."}]
		if gcse == '1':
			_messages += [{"role": "system", "content": "The patient's eyes don’t open for any reason."}]
	else:
		_messages += [{"role": "system", "content": "You do not know the patient's Eye Response score for the Glasgow Coma Scale."}]
	
	if Globals.patient.data[headers[213]] not in NA:
		var gcsv = Globals.patient.data[headers[213]]
		if gcsv == '5':
			_messages += [{"role": "system", "content": "The patient can correctly answer questions about who they are, where they’re at, the day or year, and similar questions."}]
		if gcsv == '4':
			_messages += [{"role": "system", "content": "The patient can answer questions, but their answers show they’re not fully aware of what’s happening."}]
		if gcsv == '3':
			_messages += [{"role": "system", "content": "The patient can talk and others can understand words they say, but their responses to questions don’t make sense."}]
		if gcsv == '2':
			_messages += [{"role": "system", "content": "The patient can’t talk and can only make sounds or noises."}]
		if gcsv == '1':
			_messages += [{"role": "system", "content": "The patient can't speak or make sounds."}]
	else:
		_messages += [{"role": "system", "content": "You do not know the patient's Verbal Response score for the Glasgow Coma Scale."}]
	
	if Globals.patient.data[headers[214]] not in NA:
		var gcsm = Globals.patient.data[headers[214]]
		if gcsm == '6':
			_messages += [{"role": "system", "content": "The patient follows instructions on how and when to move."}]
		if gcsm == '5':
			_messages += [{"role": "system", "content": "The patient intentionally moves away from something that presses on them."}]
		if gcsm == '4':
			_messages += [{"role": "system", "content": "The patient only moves away from something pressing on them as a reflex."}]
		if gcsm == '3':
			_messages += [{"role": "system", "content": "The patient's flex muscles (pull inward) in response to pressure."}]
		if gcsm == '2':
			_messages += [{"role": "system", "content": "The patient extends their muscles (stretch outward) in response to pressure."}]
		if gcsm == '1':
			_messages += [{"role": "system", "content": "The patient doesn't move in response to pressure."}]
	else:
		_messages += [{"role": "system", "content": "You do not know the patient's Motor Response score for the Glasgow Coma Scale."}]
	
	# MEDICATIONS
	if Globals.patient.medications:
		for med in Globals.patient.medications:
			var temp_med_str = "The patient is taking a" + ("n" if med[0][0].to_lower() in ['a', 'e', 'i', 'o', 'u'] else "") + " %s called %s with a dosage of %s via the %s route."
			_messages += [{"role": "system", "content": temp_med_str % [med[0], med[1], med[2], med[3]]}]
	else:
		_messages += [{"role": "system", "content": "The patient's medication is unknown. You must say that you are not sure about the medication the patient has taken."}]


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
