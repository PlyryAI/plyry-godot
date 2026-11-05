@tool
extends EditorPlugin

const ACCOUNT_PANEL_SCRIPT = preload("res://addons/plyry/ui/plyry_account_panel.gd")


func _enter_tree() -> void:
	add_custom_type("PlyryAccountPanel", "PanelContainer", ACCOUNT_PANEL_SCRIPT, null)


func _exit_tree() -> void:
	remove_custom_type("PlyryAccountPanel")
