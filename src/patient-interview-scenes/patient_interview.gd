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
var _lang_code: String
var _stt_audio_stream_player : AudioStreamPlayer2D
var _stt_audio_effect: AudioEffect
var _mix_rate: float
var _on_audio_loaded_callback = null
var _on_transcript_loaded_callback = null

# Patient LLM
var _chat_http_request: HTTPRequest
var _chat_endpoint: String = "https://api.openai.com/v1/chat/completions"
var _chat_model: String = "ft:gpt-4o-mini-2024-07-18:ateneo-school-of-medicine-and-public-health:patient-eng-v11:Bb0jj7Oz"
var _chat_headers: PackedStringArray
var _messages = []
var _chat_convo = []

# Mentor LLM
var _mentor_http_request: HTTPRequest
var _mentor_endpoint: String = "https://api.openai.com/v1/chat/completions"
var _mentor_model: String = "ft:gpt-4o-mini-2024-07-18:ateneo-school-of-medicine-and-public-health:mentor-v6:AjArl35r"
var _mentor_headers: PackedStringArray
var _mentor_messages = []
var _mentor_convo = []
var _mentor_context = []


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

	_on_audio_loaded_callback = JavaScriptBridge.create_callback(_on_audio_loaded)

	var audio_callback: JavaScriptObject = JavaScriptBridge.get_interface("audio_callback")

	audio_callback.dataLoaded = _on_audio_loaded_callback

	_on_transcript_loaded_callback = JavaScriptBridge.create_callback(_on_transcript_loaded)

	var transcript_callback: JavaScriptObject = JavaScriptBridge.get_interface("transcript_callback")

	transcript_callback.dataLoaded = _on_transcript_loaded_callback

	# Patient LLM
	_chat_http_request = HTTPRequest.new()
	add_child(_chat_http_request)
	_chat_http_request.timeout = 20
	_chat_http_request.request_completed.connect(_on_llm_request_completed)

	# Mentor LLM
	_mentor_http_request = HTTPRequest.new()
	add_child(_mentor_http_request)
	_mentor_http_request.timeout = 20
	_mentor_http_request.request_completed.connect(_on_mentor_request_completed)

	_load_mentor_context()

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
		JavaScriptBridge.eval("startRecording();")
	elif Input.is_action_just_released("Record"):
		JavaScriptBridge.eval("stopRecording();")


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
	if enter_here.text != "":
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
	_call_ChatGPT(text)
	_call_mentor(text)


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
	_chat_convo.append({
		"role": "Patient",
		"content": message["content"]
	})

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


func _on_tts_request_completed(result, response_code, request_headers, body) -> void:
	if result == HTTPRequest.RESULT_TIMEOUT:
		printerr("TTS request timed out!")
		return
	
	if response_code != 200:
		printerr("There was an error with the TTS module's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())
		return

	_stored_streamed_audio.clear()
	_stored_streamed_audio.append_array(body)

	var audio_stream: AudioStreamMP3 = AudioStreamMP3.new()
	audio_stream.data = _stored_streamed_audio

	_tts_audio_stream_player.set_stream(audio_stream)
	_tts_audio_stream_player.play()
	# _stored_streamed_audio.resize(0)


func _on_audio_loaded(data: Array) -> void:
	if data.size() == 0:
		return
	
	var json: JSON = JSON.new()
	var json_parse_result: int = json.parse(data[0])
	if not json_parse_result == OK:
		printerr("patient info can't be parsed as a json object")
		return
	
	var dup = json.data.duplicate(true)
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
