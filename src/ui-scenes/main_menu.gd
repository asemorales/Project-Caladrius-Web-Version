extends Control

signal obtained_info
signal obtained_histories
signal obtained_medications
signal obtained_immunizations

var _database_httprequest: HTTPRequest
var _on_secrets_loaded_callback = null
var _on_auth_token_callback = null
var _on_patient_info_callback = null
var _on_patient_history_callback = null
var _on_patient_medications_callback = null
var _on_patient_immunizations_callback = null

@onready var start_menu: MarginContainer = $StartMenu
@onready var settings_menu: MarginContainer = $SettingsMenu


func _ready() -> void:
	Globals.patient = Patient.new()

	_database_httprequest = HTTPRequest.new()
	_database_httprequest.timeout = 20
	add_child(_database_httprequest)

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
		var secrets_callback: JavaScriptObject = JavaScriptBridge.get_interface("secrets_callback")

		# Assign the callbacks
		secrets_callback.dataLoaded = _on_secrets_loaded_callback

		# Load secrets
		JavaScriptBridge.eval("loadData()")

		print("Loaded secrets via web!")

		await Globals.secrets_loaded

		# Get Google auth token
		_authenticate()

		await Globals.auth_token_loaded

		# Get patient from database
		var row = 3 + 1 # 1 = patient number
		_get_sheet_database("Patient", "A" + str(row), "HK" + str(row))
		await obtained_info

		print(Globals.patient.info)
		# _get_sheet_database("History_of_Present_Illness", "A1", "D" + str(_num_histories + 1))
		# await obtained_histories
		# _get_sheet_database("Medications", "A1", "F" + str(_num_medications + 1))
		# await obtained_medications
		# _get_sheet_database("Immunizations", "A1", "D" + str(_num_immunizations + 1))
		# await obtained_immunizations
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


# Request a new access/authentication token
func _authenticate() -> void:
	# Build an appropriate JWT
	var jwt: String = _create_jwt()

	# Create callback to get auth token through Javascript
	_on_auth_token_callback = JavaScriptBridge.create_callback(_on_auth_token_loaded)

	# Retrieve the 'gd_callbacks' object
	var auth_token_callback: JavaScriptObject = JavaScriptBridge.get_interface("auth_token_callback")

	# Assign the callbacks
	auth_token_callback.dataLoaded = _on_auth_token_callback

	# Call the Javascript function and pass the JWT to it
	JavaScriptBridge.eval("""authenticate_Google(\'%s\')""" % jwt)


# Helper function required for Google authentication to create a JSON Web Token (JWT)
func _create_jwt() -> String:
	# Access the Google Service account's key file
	# var file: FileAccess = FileAccess.open("res://auth/key_file2.json", FileAccess.READ)
	# var content_as_text: String = file.get_as_text()
	# var content_as_dictionary = JSON.parse_string(content_as_text)

	# WARNING: DO NOT PUSH THIS
	var content_as_dictionary = Globals.key_file2

	# Define the JWT header
	var jwt_header: Dictionary = {
		"alg": "RS256",
		"typ": "JWT",
		"kid": content_as_dictionary["private_key_id"]
	}

	# Build the JWT claim set
	var requested_time = Time.get_unix_time_from_system()
	var jwt_claim_set: Dictionary = {
		"iss": content_as_dictionary["client_email"],
		"scope": "https://www.googleapis.com/auth/spreadsheets",
		"aud": "https://oauth2.googleapis.com/token",
		"exp": requested_time + 3600,
		"iat": requested_time
	}
	
	# Convert base64 encoding to base64url encoding and build the raw signature
	var base64url_jwt_header: String = _base64_to_base64url(Marshalls.utf8_to_base64(JSON.stringify(jwt_header)))
	var base64url_jwt_claim_set: String = _base64_to_base64url(Marshalls.utf8_to_base64(JSON.stringify(jwt_claim_set)))
	var raw_sig: String = base64url_jwt_header + "." + base64url_jwt_claim_set
	
	# Sign the JWT
	var crypto: Crypto = Crypto.new()
	var key: CryptoKey = CryptoKey.new()
	var private_key: String = content_as_dictionary["private_key"]
	var error: int = key.load_from_string(private_key)
	if error != 0:
		push_error("Failed to load private key!")
		return ""
	var jwt_signature: PackedByteArray = crypto.sign(HashingContext.HASH_SHA256, raw_sig.sha256_buffer(), key)

	# Return the built JWT
	return raw_sig + "." + _base64_to_base64url(Marshalls.raw_to_base64(jwt_signature))


# Helper function required for Google authentication to create a JSON Web Token (JWT)
func _base64_to_base64url(string: String) -> String:
	return string.replace("+", "-").replace("/", "_").replace("=", "")


func _on_auth_token_loaded(data: Array):
	if data.size() == 0:
		return
	
	var json: JSON = JSON.new()
	var json_parse_result: int = json.parse(data[0])
	if not json_parse_result == OK:
		printerr("secrets (web) can't be parsed as a json object")
		return

	var dup = json.data.duplicate(true)
	Globals.google_auth_token = dup["access_token"]

	Globals.auth_token_loaded.emit()


# TO DO: Retrieve patient data through Javascript
func _get_sheet_database(sheet_name: String, range_start: String, range_end: String) -> void:
	match sheet_name:
		"Patient":
			_on_patient_info_callback = JavaScriptBridge.create_callback(_on_patient_info_loaded)

			# Retrieve the 'gd_callbacks' object
			var patient_info_callback: JavaScriptObject = JavaScriptBridge.get_interface("patient_info_callback")

			# Assign the callbacks
			patient_info_callback.dataLoaded = _on_patient_info_callback
		"History_of_Present_Illness":
			pass
		"Medications":
			pass
		"Immunizations":
			pass
		# "Database_Parameters":
		# 	_database_httprequest.request_completed.connect(_on_params_sheet_request_completed)
		_:
			push_warning("Unsupported sheet name in patient database!")
	
	JavaScriptBridge.eval("""fetch_database_data(\'%s\', \'%s\', \'%s\', \'%s\')""" % [Globals.google_auth_token, sheet_name, range_start, range_end])



# Called when the HTTP request to retrieve patient data is resolved
func _on_patient_info_loaded(data: Array) -> void:
	if data.size() == 0:
		return
	
	var json: JSON = JSON.new()
	var json_parse_result: int = json.parse(data[0])
	if not json_parse_result == OK:
		printerr("patient info can't be parsed as a json object")
		return
	
	var dup = json.data.duplicate(true)
	Globals.patient.set_info(dup["values"][0])

	obtained_info.emit()
	


# Called when the HTTP request to retrieve patient history data is resolved
# TO DO: Refactor
func _on_history_sheet_request_completed(result, response_code, request_headers, body) -> void:
	# Check if there was a problem retrieving the data
	var json: JSON = JSON.new()
	if response_code != 200:
		print("There was an error with Google Sheet's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())

		# # Fall back to local database copy if one exists
		# if FileAccess.file_exists("database.dat"):
		# 	print("Falling back to local copy!")
		# 	var database_file: FileAccess = FileAccess.open_encrypted_with_pass("user://database.dat", FileAccess.READ, GlobalVars.master_password)
		# 	var json_string: String = database_file.get_line()
		# 	database_file.close()
		# 	var parse_result = json.parse(json_string)
		# 	if not parse_result == OK:
		# 		print("JSON Parse Error: ", json.get_error_message(), " in ", json_string, " at line ", json.get_error_line())
		# 	history_data_file = json.data["history database"]
		# 	obtained_histories.emit()

		# 	return

	# If successful, process retrieved data
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	var values = response["values"]
	var history: Dictionary = {}
	for i in range(len(values)):
		if i == 0:
			continue
		
		if values[i][0] + " " + values[i][1] not in history:
			history[values[i][0] + " " + values[i][1]] = values[i][2]
		else:
			history[values[i][0] + " " + values[i][1]] += "; " + values[i][2]
	
	# Save data into a variable
	Globals.patient.set_history(history)

	# Signal that patient history is ready for use
	obtained_histories.emit()


# Called when the HTTP request to retrieve medication data is resolved
# TO DO: Refactor
func _on_medications_sheet_request_completed(result, response_code, request_headers, body) -> void:
	# Check if there was a problem retrieving the data
	var json: JSON = JSON.new()
	if response_code != 200:
		print("There was an error with Google Sheet's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())

		# # Fall back to local database copy if one exists
		# if FileAccess.file_exists("database.dat"):
		# 	print("Falling back to local copy!")
		# 	var database_file: FileAccess = FileAccess.open_encrypted_with_pass("user://database.dat", FileAccess.READ, GlobalVars.master_password)
		# 	var json_string: String = database_file.get_line()
		# 	database_file.close()
		# 	var parse_result: int = json.parse(json_string)
		# 	if not parse_result == OK:
		# 		print("JSON Parse Error: ", json.get_error_message(), " in ", json_string, " at line ", json.get_error_line())
		# 	medications_data_file = json.data["medications database"]
		# 	obtained_medications.emit()

		# 	return

	# If successful, process retrieved data
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	var values = response["values"]
	
	var medication: Dictionary = {}
	for i in range(len(values)):
		if i == 0:
			continue
		
		if values[i][0] + " " + values[i][1] not in medication:
			medication[values[i][0] + " " + values[i][1]] = values[i][4] + " of " + values[i][2] + " (" + values[i][3] + ") via " + values[i][5] + " administration route"
		else:
			medication[values[i][0] + " " + values[i][1]] += "; " + values[i][4] + " of " + values[i][2] + " (" + values[i][3] + ") via " + values[i][5] + " administration route"
	
	# Save data into a variable
	Globals.patient.set_medications(medication)

	# Signal that patient medication is ready for use
	obtained_medications.emit()


# Called when the HTTP request to retrieve patient immunization data is resolved
# TO DO: Refactor
func _on_immunizations_sheet_request_completed(result, response_code, request_headers, body) -> void:
	# Check if there was a problem retrieving the data
	var json: JSON = JSON.new()
	if response_code != 200:
		print("There was an error with Google Sheet's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())

		# # Fall back to local database copy if one exists
		# if FileAccess.file_exists("database.dat"):
		# 	print("Falling back to local copy!")
		# 	var database_file: FileAccess = FileAccess.open_encrypted_with_pass("user://database.dat", FileAccess.READ, GlobalVars.master_password)
		# 	var json_string: String = database_file.get_line()
		# 	database_file.close()
		# 	var parse_result: int = json.parse(json_string)
		# 	if not parse_result == OK:
		# 		print("JSON Parse Error: ", json.get_error_message(), " in ", json_string, " at line ", json.get_error_line())
		# 	immunizations_data_file = json.data["immunizations database"]
		# 	obtained_immunizations.emit()
		
		# 	return

	# If successful, process retrieved data
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	var values = response["values"]

	var immunization: Dictionary = {}
	for i in range(len(values)):
		if i == 0:
			continue
		
		if values[i][0] + " " + values[i][1] not in immunization:
			immunization[values[i][0] + " " + values[i][1]] = values[i][2] + " immunization with a dosage of " + values[i][3]
		else:
			immunization[values[i][0] + " " + values[i][1]] += "; " + values[i][2] + " immunization with a dosage of " + values[i][3]
	
	# Save data into a variable
	Globals.patient.set_immunizations(immunization)

	# Signal that patient immunization is ready for use
	obtained_immunizations.emit()