class_name PatientData
## Holds information on the AI patient.
##
## Facilitates access to patient information.


var data: Dictionary				## Keys are from the info_headers var, values are from the other vars; key = [embedding, context, info]
var info_headers: Array				## Temporarily holds the headers for the general health info
var info: Array						## Temporarily holds general health info
var history: Array[Array]			## Temporarily holds patient history
var immunizations: Array[Array]		## Temporarily holds patient immunizations
var medications: Array[Array]		## Temporarily holds patient medications
var embeddings: Array				## Temporarily holds the embeddings of the context
var context: Array					## Temporarily holds the context/prompts for rag use


func _init():
	info_headers = []
	info = []
	history = []
	medications = []
	immunizations = []
	embeddings = []
	context = []

	data = {}


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


## Set the context
func set_context(c) -> void:
	context = c


## Set the embeddings
func set_embeddings(embeds) -> void:
	embeddings = embeds


## Build the data dictionary for the patient using data from the temporary global vars
func map_info() -> void:
	# Make sure the vars are the same size
	if not info_headers.size() == info.size():
		print("Info headers array is not the same size as the info array.")
		print("Info headers size: " + str(info_headers.size()))
		print("Info size: " + str(info.size()))
		return
	elif not info_headers.size() == embeddings.size():
		print("Info headers array is not the same size as the embeddings array.")
		print("Info headers size: " + str(info_headers.size()))
		print("Embeddings size: " + str(embeddings.size()))
		return
	elif not info_headers.size() == context.size():
		print("Info headers array is not the same size as the context array.")
		print("Info headers size: " + str(info_headers.size()))
		print("Context size: " + str(context.size()))
		return

	# Build the data dictionary
	var i = 0
	for header in info_headers:
		print("Header: " + header)

		var dat = []
		if header == "History Of Present Illness":
			print("Processing history...")
			var total_history = ""
			for hist in history:
				total_history += hist[0] + "\n\n"
			
			total_history.rstrip("\n")
			dat = [str_to_var(embeddings[i].replace("\r\n", "").replace("\n", "")), context[i], total_history]
		elif header == "Medications":
			print("Processing medications...")
			dat = [str_to_var(embeddings[i].replace("\r\n", "").replace("\n", "")), context[i], medications.duplicate(true)]		# NOTE: Medications is currently the only data column that is in array[array] instead of a string
		elif header == "Immunizations":
			print("Processing immunizations...")
			var total_immunizations = ""
			for immun in immunizations:
				total_immunizations += immun[0] + "\n\n"
			
			total_immunizations.rstrip("\n")
			dat = [str_to_var(embeddings[i].replace("\r\n", "").replace("\n", "")), context[i], total_immunizations]
		else:
			dat = [str_to_var(embeddings[i].replace("\r\n", "").replace("\n", "")), context[i], info[i]]
		
		print("Data to save: ")
		print(dat)
		data[header] = dat
		i += 1
	
	# Empty the temp global vars
	info_headers.clear()
	info.clear()
	history.clear()
	medications.clear()
	immunizations.clear()
	embeddings.clear()
	context.clear()


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
