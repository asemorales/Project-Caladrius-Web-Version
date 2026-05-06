extends Node

signal secrets_loaded
signal auth_token_loaded
signal patient_data_loaded

# Secrets
var api_keys: Dictionary = { }
var key_file: Dictionary = { }
var key_file2: Dictionary = { }
var master_password: String = "HsZ#Aefxj&H&8u$gd^$UU$%5y5j!UK6BjCXWMmpsne#^GNDda!BcMWhVYZd@$*sKD9@v57GGNKzc4WhW!2tp%tzzCogoYkdT6@c4RVsK8qm4porTEhh63UC6vLMvk9s7"

# Authentication
var google_auth_token: String = ""

# User Settings
var tts: int
var stt: int
var embed: int
var volume: float

# UI Settings
var enable_case_selection: bool = true

# Patient Database Info
var max_patients: int = 0

# Patient
var patient_num: int = 1
var patient: PatientData
var language: int = 0
var personality: int = 0
