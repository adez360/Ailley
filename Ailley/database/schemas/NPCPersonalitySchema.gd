class_name NPCPersonalitySchema
extends RefCounted


## =====================================================
## NPC Personality Schema
##
## 一個 NPC = 一筆人格資料
##
## 人格系統：
##
## HEXACO
##   1. honesty_humility
##   2. emotionality
##   3. extraversion
##   4. agreeableness
##   5. conscientiousness
##   6. openness
##
## Additional Personality
##   7. diligence
##   8. courage
##   9. sociability
##   10. morality
##   11. stability
##   12. romanticism
##   13. curiosity
##   14. grudge
##   15. greed
##   16. honesty
##
## 所有數值：
##   0 - 100
##
## =====================================================


static func create(db) -> bool:

	var sql := """
	CREATE TABLE IF NOT EXISTS npc_personality (

		-- =================================================
		-- Primary Key
		-- =================================================

		personality_id INTEGER PRIMARY KEY AUTOINCREMENT,


		-- =================================================
		-- NPC
		-- 一個 NPC 對應一筆人格
		-- =================================================

		npc_id INTEGER NOT NULL UNIQUE,


		-- =================================================
		-- HEXACO
		-- =================================================

		-- 誠實謙遜
		hex_honesty INTEGER NOT NULL DEFAULT 50,

		-- 情緒起伏
		hex_emotionality INTEGER NOT NULL DEFAULT 50,

		-- 外向性
		hex_extraversion INTEGER NOT NULL DEFAULT 50,

		-- 友善性
		hex_agreeableness INTEGER NOT NULL DEFAULT 50,

		-- 嚴謹性
		hex_conscientiousness INTEGER NOT NULL DEFAULT 50,

		-- 開放性
		hex_openness INTEGER NOT NULL DEFAULT 50,


		-- =================================================
		-- Additional Personality
		-- =================================================

		-- 勤勉
		diligence INTEGER NOT NULL DEFAULT 50,

		-- 膽識
		courage INTEGER NOT NULL DEFAULT 50,

		-- 社交
		sociability INTEGER NOT NULL DEFAULT 50,

		-- 道德
		morality INTEGER NOT NULL DEFAULT 50,

		-- 情緒穩定
		stability INTEGER NOT NULL DEFAULT 50,

		-- 浪漫藝術
		romanticism INTEGER NOT NULL DEFAULT 50,

		-- 好奇心
		curiosity INTEGER NOT NULL DEFAULT 50,

		-- 記仇度
		grudge INTEGER NOT NULL DEFAULT 50,

		-- 貪婪
		greed INTEGER NOT NULL DEFAULT 50,

		-- 誠實度
		honesty INTEGER NOT NULL DEFAULT 50,


		-- =================================================
		-- Timestamp
		-- =================================================

		created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

		updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,


		-- =================================================
		-- Foreign Key
		-- =================================================

		FOREIGN KEY (npc_id)
			REFERENCES npc(npc_id)
			ON DELETE CASCADE,


		-- =================================================
		-- HEXACO CHECK
		-- =================================================

		CHECK (
			hex_honesty >= 0
			AND hex_honesty <= 100
		),

		CHECK (
			hex_emotionality >= 0
			AND hex_emotionality <= 100
		),

		CHECK (
			hex_extraversion >= 0
			AND hex_extraversion <= 100
		),

		CHECK (
			hex_agreeableness >= 0
			AND hex_agreeableness <= 100
		),

		CHECK (
			hex_conscientiousness >= 0
			AND hex_conscientiousness <= 100
		),

		CHECK (
			hex_openness >= 0
			AND hex_openness <= 100
		),


		-- =================================================
		-- Additional Personality CHECK
		-- =================================================

		CHECK (
			diligence >= 0
			AND diligence <= 100
		),

		CHECK (
			courage >= 0
			AND courage <= 100
		),

		CHECK (
			sociability >= 0
			AND sociability <= 100
		),

		CHECK (
			morality >= 0
			AND morality <= 100
		),

		CHECK (
			stability >= 0
			AND stability <= 100
		),

		CHECK (
			romanticism >= 0
			AND romanticism <= 100
		),

		CHECK (
			curiosity >= 0
			AND curiosity <= 100
		),

		CHECK (
			grudge >= 0
			AND grudge <= 100
		),

		CHECK (
			greed >= 0
			AND greed <= 100
		),

		CHECK (
			honesty >= 0
			AND honesty <= 100
		)
	);
	"""


	if not db.query(sql):

		push_error(
			"[NPCPersonalitySchema] Failed to create npc_personality table."
		)

		return false


	print(
		"[NPCPersonalitySchema] npc_personality table created successfully."
	)

	return true
