@tool
class_name TestDisplaySettings
extends McpTestSuite

const DISPLAY_SETTINGS := preload("res://scripts/core/display_settings.gd")
const AI_CONFIG := preload("res://scripts/ai/ai_config.gd")
const AGENT := preload("res://scripts/character/agent.gd")


func suite_name() -> String:
	return "display_settings"


func test_supported_fps_options_are_30_and_60() -> void:
	assert_eq(DISPLAY_SETTINGS.get_fps_options(), [30, 60])


func test_default_fps_is_30() -> void:
	assert_eq(DISPLAY_SETTINGS.DEFAULT_FPS, 30)


func test_invalid_fps_falls_back_to_30() -> void:
	assert_eq(DISPLAY_SETTINGS.normalize_fps(120), 30)


func test_agent_re_evaluation_has_a_hard_iteration_limit() -> void:
	assert_true(AGENT.MAX_REEVALUATE_ITERATIONS > 0)


func test_endpoint_classification_distinguishes_local_lan_and_cloud() -> void:
	assert_eq(AI_CONFIG.classify_endpoint("http://127.0.0.1:8080/v1"), "localhost")
	assert_eq(AI_CONFIG.classify_endpoint("http://10.167.223.10:8080/v1"), "lan")
	assert_eq(AI_CONFIG.classify_endpoint("https://api.example.com/v1"), "cloud")


func test_environment_value_is_trimmed() -> void:
	assert_eq(
		AI_CONFIG.environment_override(
			{"AILLEY_AI_BASE_URL": " http://10.167.223.10:8080/v1/ "},
			"AILLEY_AI_BASE_URL"
		),
		"http://10.167.223.10:8080/v1/"
	)
