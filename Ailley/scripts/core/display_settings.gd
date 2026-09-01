class_name DisplaySettings
extends RefCounted

const SETTINGS_PATH := "user://display_settings.cfg"
const DEFAULT_FPS := 30
const FPS_OPTIONS: Array[int] = [30, 60]


static func get_fps_options() -> Array[int]:
	return FPS_OPTIONS.duplicate()


static func normalize_fps(value: int) -> int:
	return value if FPS_OPTIONS.has(value) else DEFAULT_FPS


static func apply_fps(value: int) -> int:
	var fps := normalize_fps(value)
	Engine.max_fps = fps
	return fps


static func load_fps() -> int:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return DEFAULT_FPS
	return normalize_fps(int(config.get_value("display", "fps", DEFAULT_FPS)))


static func apply_saved_fps() -> int:
	return apply_fps(load_fps())


static func save_fps(value: int) -> int:
	var fps := apply_fps(value)
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("display", "fps", fps)
	if config.save(SETTINGS_PATH) != OK:
		push_error("DisplaySettings: unable to save FPS setting")
	return fps
