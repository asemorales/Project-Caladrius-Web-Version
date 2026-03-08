extends Node

signal secrets_loaded

# Secret
var api_keys: Dictionary = { }
var key_file: Dictionary = { }
var key_file2: Dictionary = { }
var master_password: String = "HsZ#Aefxj&H&8u$gd^$UU$%5y5j!UK6BjCXWMmpsne#^GNDda!BcMWhVYZd@$*sKD9@v57GGNKzc4WhW!2tp%tzzCogoYkdT6@c4RVsK8qm4porTEhh63UC6vLMvk9s7"

# Settings
var tts: int
var stt: int
var volume: float

# Patient
var language: int