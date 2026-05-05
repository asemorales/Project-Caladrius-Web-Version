extends Control

signal obtained_database_data

var _database_httprequest: HTTPRequest
var _database_params: Dictionary = {}
var _patient_name: Array = []
var _on_secrets_loaded_callback = null
var _on_auth_token_callback = null
var _on_database_callback = null

var main_menu
@onready var start_menu: MarginContainer = $StartMenu
@onready var settings_menu: MarginContainer = $SettingsMenu
@onready var case_selection_menu: MarginContainer = $CaseSelectionMenu


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
	# If the program is run on the web
	if (OS.get_name() == "Web"):
		# Setup Godot <-> Browser communication for loading secrets (TEMPORARY)
		_on_secrets_loaded_callback = JavaScriptBridge.create_callback(_on_secrets_loaded)				# Create a callback and save into a global var
		var secrets_callback: JavaScriptObject = JavaScriptBridge.get_interface("secrets_callback")		# Get the Javascript var to setup a callback with
		secrets_callback.dataLoaded = _on_secrets_loaded_callback										# Connect the Javascript var to the Godot function

		# Load secrets (TEMPORARY)
		JavaScriptBridge.eval("loadData();")

		# Start the loading screen
		main_menu.loading_screen.start_loading_screen()

		# Wait until secrets is loaded
		await Globals.secrets_loaded

		# Get Google auth token
		_authenticate()

		# Wait until the Google auth token is obtained
		await Globals.auth_token_loaded

		# Setup Godot <-> Browser communication for loading the database
		_on_database_callback = JavaScriptBridge.create_callback(_on_database_data_loaded)
		var database_callback: JavaScriptObject = JavaScriptBridge.get_interface("database_callback")
		database_callback.dataLoaded = _on_database_callback

		# Retrieve database params
		_get_sheet_database("Database_Parameters", "A2", "D2")
		await obtained_database_data

		# Make the user choose a case if enabled
		if Globals.enable_case_selection:
			start_menu.visible = false
			main_menu.loading_screen.stop_loading_screen()
			case_selection_menu.visible = true
			await case_selection_menu.case_selected
			main_menu.loading_screen.start_loading_screen()

		# Retrieve patient headers
		var header_row = 3
		_get_sheet_database("Headers", "A" + str(header_row), "BC" + str(header_row))
		await obtained_database_data

		# Retrieve patient info
		var row = header_row + Globals.patient_num
		_get_sheet_database("Patient", "A" + str(row), "BC" + str(row))
		await obtained_database_data

		_get_sheet_database("Context", "A" + str(row), "BC" + str(row))
		await obtained_database_data

		_get_sheet_database("Embeddings", "A" + str(row), "BC" + str(row))
		await obtained_database_data

		# Retrieve the rest of the information
		_get_sheet_database("History_of_Present_Illness", "A2", "C" + str(_database_params["Histories"] + 1))
		await obtained_database_data

		_get_sheet_database("Medications", "A2", "F" + str(_database_params["Medications"] + 1))
		await obtained_database_data

		_get_sheet_database("Immunizations", "A2", "C" + str(_database_params["Immunizations"] + 1))
		await obtained_database_data

		print("Retrieved all relevant info from the database!")

		# Build the patient dictionary
		Globals.patient.map_info()

		# Signal that the patient's data is fully loaded
		Globals.patient_data_loaded.emit()

		print("Patient data fully loaded!")
		
		# Load the patient model based on the retrieved patient data
		main_menu.patient_interview.load_patient_model(int(Globals.patient.data["Age"][2]), Globals.patient.data["Sex"][2])
		
		print("Patient model fully loaded!")

		# Close the loading screen
		main_menu.loading_screen.stop_loading_screen()
	
	# If the program is run as an executable (for DEBUG testing only)
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


# Splits the string into an array of tokens (strings)
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


# Uses a bag of words approach to obtain the vector of a string
# Adds the vectors of each word in the string then divides it by the number of words in the string with vectors found in the local embeddings database
# TO UPDATE
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

			var size = vector.size()
			if not size == 50:
				print("Word vector was initialized with the wrong size!")

			average += 1
		else:
			assert (vector.size() == word_vector.size())

			for i in range(vector.size()):
				vector[i] += word_vector[i]
			
			average += 1
	
	if vector.size() == 0:
		print("Vector of %s is empty!" % string)
	elif not vector.size() == 50:
		print("Vector of %s was built with the wrong size!" % string)
	
	for i in range(vector.size()):
		vector[i] /= average
	
	if vector.size() == 0:
		print("Final vector of %s is empty!" % string)
	elif not vector.size() == 50:
		print("Final vector of %s is not the correct size!" % string)
	
	return vector


# Finds the word's vector from the local embeddings database
func _get_word_vector(word: String) -> Array:
	if word in Embeddings.data:
		return Embeddings.data[word]
	else:
		return []


# Callback for when the secrets Javascript var is loaded
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


# Request a new google access/authentication token
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


# Called when the HTTPRequest used to obtain the Google auth token resolves
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
	# Check to see if the sheet_name is supported by the program
	match sheet_name:
		"Headers":
			pass
		"Patient":
			pass
		"Context":
			pass
		"Embeddings":
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
	
	# Call the Javascript function responsible for retrieving data from the GSheet
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
	print("Retrieved " + dup["sheet_name"] + " data:")
	print(dup)
	match dup["sheet_name"]:
		"Headers":
			Globals.patient.set_info_headers(dup["values"][0])

			# for header in Globals.patient.info_headers:
			# 	Embeddings.header_embeddings_data[header] = _get_string_vector(header)
		"Database_Parameters":
			_database_params["Patients"] = int(dup["values"][0][0])
			_database_params["Histories"] = int(dup["values"][0][1])
			_database_params["Medications"] = int(dup["values"][0][2])
			_database_params["Immunizations"] = int(dup["values"][0][3])

			Globals.max_patients = _database_params["Patients"]
		"Patient":
			Globals.patient.set_info(dup["values"][0])
			_patient_name.append(dup["values"][0][0])
			_patient_name.append(dup["values"][0][1])

			print("Patient info:")
			print(dup["values"][0])
		"Context":
			Globals.patient.set_context(dup["values"][0])

			print("Context:")
			print(dup["values"][0])
		"Embeddings":
			Globals.patient.set_embeddings(dup["values"][0])

			print("Embeddings:")
			print(dup["values"][0])
		"History_of_Present_Illness":
			print("History:")
			print(dup["values"])

			for history in dup["values"]:
				if not history.size() == 3:
					push_warning("Invalid history size!")
					continue

				if history[0] == _patient_name[0] and history[1] == _patient_name[1]:
					Globals.patient.add_history([history[2]])
		"Medications":
			print("Medications:")
			print(dup["values"])

			for medication in dup["values"]:
				if not medication.size() == 6:
					push_warning("Invalid medication size!")
					continue
				
				if medication[0] == _patient_name[0] and medication[1] == _patient_name[1]:
					Globals.patient.add_medication(medication.slice(2, 6))
		"Immunizations":
			print("Immunizations:")
			print(dup["values"])

			for immunization in dup["values"]:
				if not immunization.size() == 3:
					push_warning("Invalid immunization size!")
					continue
				
				if immunization[0] == _patient_name[0] and immunization[1] == _patient_name[1]:
					Globals.patient.add_immunization([immunization[2]])

	obtained_database_data.emit()
