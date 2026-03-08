extends Node2D

@export var freq_penalty: float = 0
@export var max_tokens: int = 1024
@export var presence_penalty: float = 0
@export var stream: bool = false
@export var temp: float = 1

var _endpoint: String = "https://api.openai.com/v1/chat/completions"
var _model: String = "ft:gpt-4o-mini-2024-07-18:ateneo-school-of-medicine-and-public-health:patient-eng-v11:Bb0jj7Oz"
var _headers
var _http_request: HTTPRequest
var _messages = []
# var _audio_stream_player: AudioStreamPlayer

@onready var enter_here: TextEdit = $CanvasLayer/HBoxContainer/CenterContainer/MarginContainer/EnterHere
@onready var transcript: RichTextLabel = $CanvasLayer/CenterContainer2/VBoxContainer/MarginContainer/Transcript
@onready var mentor_comment: RichTextLabel = $CanvasLayer/CenterContainer2/VBoxContainer/MarginContainer2/MarginContainer/VBoxContainer/MentorComment


func _ready() -> void:
	_http_request = HTTPRequest.new()
	add_child(_http_request)
	_http_request.timeout = 20
	_http_request.request_completed.connect(_on_request_completed)
	
	await Globals.secrets_loaded
	
	_headers = PackedStringArray(["Content-type: application/json", "Authorization: Bearer " + Globals.api_keys["ChatGPT"]])


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("Record"):
		print("Pressed")
	elif Input.is_action_just_released("Record"):
		print("Released")


func _on_enter_button_pressed() -> void:
	if enter_here.text != "":
		transcript.append_text("Doctor: " + enter_here.text + "\n")

		call_ChatGPT(enter_here.text)

		enter_here.text = ""


## Sends text to ChatGPT to receive a response
func call_ChatGPT(text: String) -> void:
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
		"model": _model,
		"frequency_penalty": freq_penalty,
		"max_tokens": max_tokens,
		"presence_penalty": presence_penalty,
		"stream": stream,
		"temperature": temp
	})

	# Send the HTTP request
	var error: int = _http_request.request(_endpoint, _headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		push_error("An error occurred in the HTTP request.")


func _on_request_completed(result, response_code, request_headers, body) -> void:
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
	# _npc.call_tts(message_text)

	# # Save a local transcript of the conversation
	# save_convo()
