class_name Workstation
extends StaticBody2D

## 可以工作賺錢的地點。距離判定交給 Character.find_nearest_workstation()／
## work_at() 做（跟 TALK_RANGE 同一種簡單距離檢查，見 character.gd 的
## "---- 工作 ----" 那節），這裡自己不查距離，只管「誰現在佔用著」。
##
## StaticBody2D + CollisionShape2D 純粹是給 NavGrid 用的——NavGrid 的
## rebuild() 是物理查詢，場景裡隨手擺的 StaticBody2D 會自動被算成障礙
## （見 nav_grid.gd 開頭註解），角色不會穿過桌子走位。互動判定本身
## 不靠這個碰撞體。
##
## 同一時間只有一個角色能用同一張工作站，靠 occupant 卡位——work_at()
## 呼叫 try_occupy() 失敗就回 Character.WORK_OCCUPIED，不會兩個角色
## 同時在同一張桌子上領錢。

var occupant: Character = null


func _ready() -> void:
	add_to_group("workstations")

# 用 is_instance_valid() 不用 `occupant != null`：Godot 4 裡被 free 掉的物件
# `!= null` 仍然成立，所以佔用者被移除（換場景、日後的 despawn）之後，工作站會
# 永遠回報「有人在用」，而 release() 比對的是一個已經不存在的角色，永遠清不掉。
# 這裡也是「角色工作到一半被 free」時唯一會把位子放出來的地方
func is_occupied() -> bool:
	return is_instance_valid(occupant)

func try_occupy(character: Character) -> bool:
	if is_occupied():
		return false
	occupant = character
	return true

# 忽略不是目前佔用者的呼叫——角色重複呼叫、或工作中途被打斷後又收到一次
# release，都不該把別人剛卡上的位子清掉
func release(character: Character) -> void:
	if occupant == character:
		occupant = null
