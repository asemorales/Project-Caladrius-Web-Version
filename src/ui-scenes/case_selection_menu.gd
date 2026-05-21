extends MarginContainer

signal case_selected

var saved_patient_edit_text: String

@onready var _patient_edit: LineEdit = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/HBoxContainer/PatientEdit
@onready var _language_button: OptionButton = $VBoxContainer/CenterContainer/MarginContainer/HBoxContainer/VBoxContainer2/LanguageButton


func _ready() -> void:
	saved_patient_edit_text = _patient_edit.text


func on_select_button_pressed() -> void:
	Globals.patient_num = int(_patient_edit.text)

	# Redundancy just in case
	Globals.language = _language_button.get_selected_id()

	# Tell the embedding web shell (Caladrius) to create a Simulation row so
	# the End Consult transcript + grades have somewhere to land. No-op on
	# native builds.
	if OS.has_feature("web"):
		var payload := JSON.stringify({
			"patient_num": Globals.patient_num,
			"language": Globals.language,
		})
		JavaScriptBridge.eval("if (window.startSimulation) window.startSimulation(" + payload + ");")

	case_selected.emit()


func on_left_button_pressed() -> void:
	var patient_num: int = int(_patient_edit.text)
	if patient_num - 1 <= 0:
		patient_num = Globals.max_patients
	else:
		patient_num -= 1

	_patient_edit.text = str(patient_num)


func on_right_button_pressed() -> void:
	var patient_num: int = int(_patient_edit.text)
	if patient_num + 1 > Globals.max_patients:
		patient_num = 1
	else:
		patient_num += 1
	
	_patient_edit.text = str(patient_num)


func on_patient_edit_text_changed(new_text: String) -> void:
	var regex: RegEx = RegEx.new()
	regex.compile("[^0-9]")

	var match: RegExMatch = regex.search(new_text)
	if not match:
		saved_patient_edit_text = new_text
		return
	
	_patient_edit.text = saved_patient_edit_text


func on_patient_edit_text_submitted(_new_text: String) -> void:
	var patient_num: int = int(_patient_edit.text)
	if patient_num > Globals.max_patients:
		patient_num = Globals.max_patients
	elif patient_num <= 0:
		patient_num = 1
	
	_patient_edit.text = str(patient_num)


func on_language_button_item_selected(index: int) -> void:
	Globals.language = _language_button.get_selected_id()
