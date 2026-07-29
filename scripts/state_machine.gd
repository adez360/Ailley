extends Node


signal state_changed


enum State {
	IDLE,
	WANDER,
	WORK
}


var current_state = State.IDLE


var timer = 0.0



func _ready():

	change_state(State.IDLE)



func _process(delta):

	timer -= delta

	if timer <= 0:

		switch_state()



func switch_state():

	if current_state == State.IDLE:

		change_state(State.WANDER)

	else:

		change_state(State.IDLE)



func change_state(new_state):

	current_state = new_state

	state_changed.emit()

	match current_state:

		State.IDLE:

			timer = 3
			print("村民休息")


		State.WANDER:

			timer = 5
			print("村民閒逛")
