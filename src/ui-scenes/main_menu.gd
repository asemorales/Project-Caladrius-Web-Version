extends Control

signal obtained_database_data

var _database_httprequest: HTTPRequest
var _database_params: Dictionary = {}
var _on_secrets_loaded_callback = null
var _on_auth_token_callback = null
var _on_database_callback = null

var main_menu
@onready var start_menu: MarginContainer = $StartMenu
@onready var settings_menu: MarginContainer = $SettingsMenu


func _ready() -> void:
	main_menu = get_tree().root.get_node("Main")
	Globals.patient = PatientData.new()

	_database_httprequest = HTTPRequest.new()
	_database_httprequest.timeout = 20
	add_child(_database_httprequest)

	_database_params["Patients"] = 0
	_database_params["Histories"] = 0
	_database_params["Medications"] = 0
	_database_params["Immunizations"] = 0

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
		JavaScriptBridge.eval("loadData();")

		print("Loaded secrets via web!")

		main_menu.loading_screen.start_loading_screen()

		await Globals.secrets_loaded

		# Get Google auth token
		_authenticate()

		await Globals.auth_token_loaded

		_on_database_callback = JavaScriptBridge.create_callback(_on_database_data_loaded)

		var database_callback: JavaScriptObject = JavaScriptBridge.get_interface("database_callback")

		database_callback.dataLoaded = _on_database_callback

		# Get patient from database
		_get_sheet_database("Database_Parameters", "A2", "D2")
		await obtained_database_data

		var header_row = 3
		_get_sheet_database("Headers", "A" + str(header_row), "HK" + str(header_row))
		await obtained_database_data

		var row = 3 + 1 # 1 = patient number 1 (temporarily hard coded to patient 1 for testing)
		_get_sheet_database("Patient", "A" + str(row), "HK" + str(row))
		await obtained_database_data

		Globals.patient.map_info()

		_get_sheet_database("History_of_Present_Illness", "A1", "D" + str(_database_params["Histories"] + 1))
		await obtained_database_data

		_get_sheet_database("Medications", "A1", "F" + str(_database_params["Medications"] + 1))
		await obtained_database_data

		_get_sheet_database("Immunizations", "A1", "D" + str(_database_params["Immunizations"] + 1))
		await obtained_database_data

		Globals.patient_data_loaded.emit()
		
		main_menu.patient_interview.load_patient_model(int(Globals.patient.data["Age"]), Globals.patient.data["Sex"])
		
		main_menu.loading_screen.stop_loading_screen()
		print(Globals.patient)
		print(Globals.patient.data)
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
	JavaScriptBridge.eval("""authenticate_Google(\'%s\');""" % jwt)


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


func _get_sheet_database(sheet_name: String, range_start: String, range_end: String) -> void:
	match sheet_name:
		"Headers":
			pass
		"Patient":
			pass
		"History_of_Present_Illness":
			pass
		"Medications":
			pass
		"Immunizations":
			pass
		"Database_Parameters":
			pass
		_:
			push_warning("Unsupported sheet name in patient database!")
	
	JavaScriptBridge.eval("""fetch_database_data(\'%s\', \'%s\', \'%s\', \'%s\');""" % [Globals.google_auth_token, sheet_name, range_start, range_end])


func _on_database_data_loaded(data: Array) -> void:
	if data.size() == 0:
		return
	
	var json: JSON = JSON.new()
	var json_parse_result: int = json.parse(data[0])
	if not json_parse_result == OK:
		printerr("patient info can't be parsed as a json object")
		return
	
	var dup = json.data.duplicate(true)
	match dup["sheet_name"]:
		"Headers":
			Globals.patient.set_info_headers(dup["values"][0])
		"Database_Parameters":
			_database_params["Patients"] = int(dup["values"][0][0])
			_database_params["Histories"] = int(dup["values"][0][1])
			_database_params["Medications"] = int(dup["values"][0][2])
			_database_params["Immunizations"] = int(dup["values"][0][3])
		"Patient":
			Globals.patient.set_info(dup["values"][0])
		"History_of_Present_Illness":
			for history in dup["values"]:
				if history[0] == Globals.patient.data[Globals.patient.data.keys()[0]] and history[1] == Globals.patient.data[Globals.patient.data.keys()[1]]:
					var temp_array = []
					temp_array.append_array(history.slice(2, 4))
					Globals.patient.add_history(temp_array)
		"Medications":
			for medication in dup["values"]:
				if medication[0] == Globals.patient.data[Globals.patient.data.keys()[0]] and medication[1] == Globals.patient.data[Globals.patient.data.keys()[1]]:
					var temp_array = []
					temp_array.append_array(medication.slice(2, 6))
					Globals.patient.add_medication(temp_array)
		"Immunizations":
			for immunization in dup["values"]:
				if immunization[0] == Globals.patient.data[Globals.patient.data.keys()[0]] and immunization[1] == Globals.patient.data[Globals.patient.data.keys()[1]]:
					var temp_array = []
					temp_array.append_array(immunization.slice(2, 4))
					Globals.patient.add_immunization(temp_array)

	obtained_database_data.emit()
