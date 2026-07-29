extends Node
func load_json(path:String):
	var file = FileAccess.open(path, FileAccess.READ)
	
	if file == null:
		return null
		
	var text = file.get_as_text()
	file.close()
	var data = JSON.parse_string(text)
	return data
