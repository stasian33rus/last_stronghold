extends Node
## Bootstrap дымотеста: сцена tests/smoke_test.tscn загружается как обычный main scene
## (autoload'ы активны), а сам тестовый раннер переносится в root, чтобы пережить
## смену сцены меню -> арена внутри теста.
## Запуск: godot --headless res://tests/smoke_test.tscn

func _ready() -> void:
	var script := load("res://tests/smoke_runner.gd")
	var runner := Node.new()
	runner.name = "SmokeRunner"
	runner.set_script(script)
	get_tree().root.call_deferred("add_child", runner)
