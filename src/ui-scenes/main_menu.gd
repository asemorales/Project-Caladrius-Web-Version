extends Control

var _on_secrets_loaded_callback = null

@onready var start_menu: MarginContainer = $StartMenu
@onready var settings_menu: MarginContainer = $SettingsMenu


func _ready() -> void:
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
		var gdcallbacks: JavaScriptObject = JavaScriptBridge.get_interface("gd_callbacks")

		# Assign the callbacks
		gdcallbacks.dataLoaded = _on_secrets_loaded_callback

		# Load secrets
		JavaScriptBridge.eval("loadData()")

		print("Loaded secrets via web!")

		await Globals.secrets_loaded

		# Get Google auth token
		_authenticate()

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

	# Call the javascript function and pass the JWT to it
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