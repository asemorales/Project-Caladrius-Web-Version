class_name PatientData
## Holds information on the AI patient.
##
## Facilitates access to patient information.

var info_headers: Array				## Temporarily holds the headers for the general health info
var info: Array						## Temporarily holds general health info
var data: Dictionary				## Holds general health info mapped to their respective headers
var history: Array[Array]			## Holds patient history
var immunizations: Array[Array]		## Holds patient immunizations
var medications: Array[Array]		## Holds patient medications


func _init():
	info_headers = []
	info = []

	data = {}
	history = []
	medications = []
	immunizations = []


## Set headers for the general health
func set_info_headers(value) -> void:
	info_headers = value


## Set the general health info
func set_info(value) -> void:
	info = value


## Add history info
func add_history(hist) -> void:
	history.append(hist)


## Add immunization info
func add_immunization(immun) -> void:
	immunizations.append(immun)


## Add medication info
func add_medication(med) -> void:
	medications.append(med)


func map_info() -> void:
	assert(info_headers.size() == info.size())

	var i = 0
	for header in info_headers:
		data[header] = info[i]
		i += 1
	
	info_headers.clear()
	info.clear()


## Convert a patient field to its respective index
func to_index(field) -> int:
	var keys = data.keys()
	if not keys.has(field):
		return -1

	return keys.find(field)


## Convert an index to its respective patient field
func to_field(index) -> String:
	var keys = data.keys()
	if index < 0 or index >= keys.size():
		return ""

	return keys[index]
