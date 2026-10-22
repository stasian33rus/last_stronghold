extends Node
func _ready() -> void:
	var script := load("res://tests/debug_giga_runner.gd")
	var runner := Node.new()
	runner.name = "DebugGigaRunner"
	runner.set_script(script)
	get_tree().root.add_child.call_deferred(runner)
