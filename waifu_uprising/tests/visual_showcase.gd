extends Node
## Bootstrap визуальной витрины (аналог smoke_test.gd): раннер переносится в
## root, чтобы пережить смену сцены меню -> арена.
## Запуск: xvfb-run -a godot --rendering-driver opengl3 --rendering-method
##   gl_compatibility --path . res://tests/visual_showcase.tscn -- +shotdir=/abs
func _ready() -> void:
	var script := load("res://tests/visual_showcase_runner.gd")
	var runner := Node.new()
	runner.name = "VisualShowcaseRunner"
	runner.set_script(script)
	get_tree().root.call_deferred("add_child", runner)
