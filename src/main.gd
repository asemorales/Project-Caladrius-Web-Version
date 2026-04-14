extends Node

signal authenticated

var _http_request_auth: HTTPRequest
var _access_token_requested_time: float
var _access_token

@onready var loading_screen := $LoadingScreenLayer/LoadingScreen
@onready var main_menu := $MainMenuLayer/MainMenu


func _ready() -> void:
	#loading_screen.start_loading_screen()

	JavaScriptBridge.eval("setupAudio();")

	# await authenticated
	#await get_tree().create_timer(5).timeout
	main_menu.visible = true
	#loading_screen.stop_loading_screen()


func _is_access_token_valid() -> bool:
	# Check if cookies are persistent
	if not OS.is_userfs_persistent():
		print("WARNING: Cookies are not persistent!")
		return false
	
	# Check if the stored auth token exists
	if not FileAccess.file_exists("user://auth_datasheet_test"):
		return false
	
	# Check the data of the stored auth token
	# Get the data
	var json: JSON = JSON.new()
	var file_access: FileAccess = FileAccess.open("user://auth_datasheet_test", FileAccess.READ)
	var json_string: String = file_access.get_line()
	file_access.close()

	# Parse the data
	var json_parse_result: int = json.parse(json_string)
	if not json_parse_result == OK:
		printerr("auth_datasheet can't be parsed as a json object")
		return false
	
	# Check if the data is structured as expected
	if not json.data.get("GoogleSheets") or not json.data["GoogleSheets"].get("obtained") or not json.data["GoogleSheets"].get("expires_in") or not json.data["GoogleSheets"].get("access_token"):
		return false
	
	# Check the expiry
	var obtained_time: float = json.data["GoogleSheets"]["obtained"]
	var expiry: float = obtained_time + json.data["GoogleSheets"]["expires_in"]
	if Time.get_unix_time_from_system() + 60 < expiry: # 60 = buffer
		_access_token = json.data["GoogleSheets"]["access_token"]
		return true
	return false


# Request a new access/authentication token
func _authenticate() -> void:
	# Build an appropriate JWT
	var jwt: String = _create_jwt()

	# Prepare the request headers and body
	# TO DO: Fix this. Response headers exist but the body is empty.
	# var headers: PackedStringArray = PackedStringArray(["Access-Control-Allow-Origin: *"])
	var headers: PackedStringArray = PackedStringArray([])
	var body: String = JSON.stringify({
		"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
		"assertion": jwt
	})

	# Make the HTTP request
	var error: int = _http_request_auth.request("https://oauth2.googleapis.com/token", headers, HTTPClient.METHOD_POST, body)
	if error != OK:
		push_error("An error occurred in the HTTP request.")


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


func _on_auth_request_completed(result, response_code, request_headers, body) -> void:
	# Debug output when an error occurs
	if response_code != 200:
		push_error("There was an error with Google Sheet Authentication's response, response code:" + str(response_code))
		print(result)
		print(request_headers)
		print(body.get_string_from_utf8())
		return

	# Obtain token and its expiry
	var json: JSON = JSON.new()
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()

	# DEBUG
	print("Headers:")
	print(request_headers)
	print("Body:")
	print(body)
	print("Response:")
	print(response)

	var access_token = response["access_token"]
	var _expires_in = response["expires_in"]

	# Save token, expiry, and request time to a JSON file
	var file_access: FileAccess = FileAccess.open("user://auth_datasheet_test", FileAccess.WRITE)
	var json_string: String = JSON.stringify({
		"GoogleSheets": {
			"token_type": "Bearer",
			"access_token": access_token,
			"obtained": _access_token_requested_time,
			"expires_in": _expires_in
		}
	})
	file_access.store_line(json_string)
	file_access.close()

	# Signal that authentication is complete
	authenticated.emit()
