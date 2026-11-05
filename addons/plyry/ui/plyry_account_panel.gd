@tool
extends PanelContainer

## Optional local sign-in/sign-up panel. It uses the Plyry API and Godot Controls;
## it never embeds a Plyry website page. Assign a Theme or replace this script.

@export_node_path("Node") var client_path: NodePath
@export var custom_theme: Theme
@export_range(0, 48, 1) var content_spacing: int = 10
@export var title_text: String = "Connect to Plyry"
@export var connected_title_text: String = "Connected to Plyry"
@export var signup_title_text: String = "Create a Plyry account"
@export var description_text: String = "Sign in to link this app to your Plyry account."
@export var signup_description_text: String = "Create your account and link it to this app."
@export var email_placeholder: String = "Email"
@export var password_placeholder: String = "Password"
@export var answer_placeholder_text: String = "Answer"
@export var preparing_signup_status_text: String = "Preparing account creation…"
@export var signup_required_status_text: String = "This email does not have an account yet. Choose Create account to continue."
@export var signup_email_required_status_text: String = "Enter your email address to get the signup check."
@export var signup_check_failed_status_text: String = "A signup check could not be created."
@export var signup_check_incomplete_status_text: String = "Plyry returned an incomplete signup check. Try again."
@export var signup_check_fallback_question_text: String = "Answer the signup check."
@export var sign_in_button_text: String = "Sign in"
@export var create_account_button_text: String = "Create account"
@export var back_to_sign_in_button_text: String = "Back to sign in"
@export var sign_out_button_text: String = "Sign out"
@export var connected_status_text: String = "Connected to Plyry."
@export var api_key_status_text: String = "Plyry API key access is active."
@export var signed_in_as_status_format: String = "Signed in as {email}"
@export var signed_out_status_text: String = "Signed out."
@export var sign_out_unconfirmed_status_text: String = "Signed out locally. The server could not confirm revocation."
@export var session_restored_status_text: String = "Session restored."
@export var request_failed_status_text: String = "Plyry could not complete the request."
@export var signing_in_status_text: String = "Connecting…"
@export var signing_out_status_text: String = "Signing out…"
@export var missing_client_status_text: String = "Add a PlyryClient node to the scene and assign it to this panel."
@export var allow_signup: bool = true

var _client: PlyryClient
var _layout: VBoxContainer
var _title_label: Label
var _description_label: Label
var _status_label: Label
var _email_input: LineEdit
var _password_input: LineEdit
var _challenge_box: VBoxContainer
var _challenge_question: Label
var _answer_input: LineEdit
var _primary_button: Button
var _mode_button: Button
var _sign_out_button: Button
var _signup_mode: bool = false
var _signup_challenge: String = ""


func _ready() -> void:
	if custom_theme != null:
		theme = custom_theme
	if _layout == null:
		_build_ui()
	if Engine.is_editor_hint():
		return
	_client = get_node_or_null(client_path) as PlyryClient if not client_path.is_empty() else null
	if _client == null:
		var clients := get_tree().get_nodes_in_group("plyry_client")
		if not clients.is_empty():
			_client = clients[0] as PlyryClient
	if _client == null:
		_set_status(missing_client_status_text)
		_set_busy(true)
		return
	_client.session_changed.connect(_on_session_changed)
	_client.token_store_warning.connect(_on_token_store_warning)
	_refresh_account_view()
	if _client.token_store != null:
		call_deferred("_restore_saved_session")


func _build_ui() -> void:
	_layout = VBoxContainer.new()
	_layout.add_theme_constant_override("separation", content_spacing)
	add_child(_layout)

	_title_label = Label.new()
	_title_label.text = title_text
	_title_label.add_theme_font_size_override("font_size", 22)
	_layout.add_child(_title_label)

	_description_label = Label.new()
	_description_label.text = description_text
	_description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_layout.add_child(_description_label)

	_email_input = LineEdit.new()
	_email_input.placeholder_text = email_placeholder
	_email_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS
	_email_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layout.add_child(_email_input)

	_password_input = LineEdit.new()
	_password_input.placeholder_text = password_placeholder
	_password_input.secret = true
	_password_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PASSWORD
	_password_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layout.add_child(_password_input)

	_challenge_box = VBoxContainer.new()
	_challenge_box.add_theme_constant_override("separation", content_spacing)
	_challenge_box.visible = false
	_layout.add_child(_challenge_box)
	_challenge_question = Label.new()
	_challenge_question.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_challenge_box.add_child(_challenge_question)
	_answer_input = LineEdit.new()
	_answer_input.placeholder_text = answer_placeholder_text
	_answer_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_challenge_box.add_child(_answer_input)

	_primary_button = Button.new()
	_primary_button.text = sign_in_button_text
	_primary_button.pressed.connect(_on_primary_pressed)
	_layout.add_child(_primary_button)

	_mode_button = Button.new()
	_mode_button.text = create_account_button_text
	_mode_button.flat = true
	_mode_button.visible = allow_signup
	_mode_button.pressed.connect(_on_mode_pressed)
	_layout.add_child(_mode_button)

	_sign_out_button = Button.new()
	_sign_out_button.text = sign_out_button_text
	_sign_out_button.visible = false
	_sign_out_button.pressed.connect(_on_sign_out_pressed)
	_layout.add_child(_sign_out_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_layout.add_child(_status_label)


func _on_primary_pressed() -> void:
	if Engine.is_editor_hint() or _client == null:
		return
	_set_busy(true, signing_in_status_text)
	var response: PlyryApiResponse
	if _signup_mode:
		response = await _client.sign_up(_email_input.text, _password_input.text, _signup_challenge, _answer_input.text)
	else:
		response = await _client.sign_in(_email_input.text, _password_input.text)
	_set_busy(false)
	if response.ok:
		_signup_mode = false
		_challenge_box.visible = false
		_password_input.clear()
		_answer_input.clear()
		_set_status(connected_status_text)
		_refresh_account_view()
		return
	_set_status(response.message if not response.message.is_empty() else request_failed_status_text)
	if response.error_code == "signup_required" and allow_signup:
		_set_status(signup_required_status_text)


func _on_mode_pressed() -> void:
	if Engine.is_editor_hint() or _client == null or not allow_signup:
		return
	if _signup_mode:
		_signup_mode = false
		_signup_challenge = ""
		_challenge_box.visible = false
		_primary_button.text = sign_in_button_text
		_mode_button.text = create_account_button_text
		_description_label.text = description_text
		_set_status("")
		return
	if _email_input.text.strip_edges().is_empty():
		_set_status(signup_email_required_status_text)
		return
	_set_busy(true, preparing_signup_status_text)
	var response := await _client.create_signup_challenge(_email_input.text)
	_set_busy(false)
	if not response.ok or not response.data is Dictionary:
		_set_status(response.message if not response.message.is_empty() else signup_check_failed_status_text)
		return
	_signup_challenge = str(response.data.get("signup_challenge", ""))
	if _signup_challenge.is_empty():
		_set_status(signup_check_incomplete_status_text)
		return
	_signup_mode = true
	_challenge_question.text = str(response.data.get("question", signup_check_fallback_question_text))
	_challenge_box.visible = true
	_primary_button.text = create_account_button_text
	_mode_button.text = back_to_sign_in_button_text
	_description_label.text = signup_description_text
	_set_status("")


func _on_sign_out_pressed() -> void:
	if Engine.is_editor_hint() or _client == null:
		return
	_set_busy(true, signing_out_status_text)
	var response := await _client.sign_out()
	_set_busy(false)
	_set_status(signed_out_status_text if response.ok else sign_out_unconfirmed_status_text)
	_refresh_account_view()


func _restore_saved_session() -> void:
	if _client == null:
		return
	var response := await _client.restore_session()
	if response.ok:
		_set_status(session_restored_status_text)
	elif response.error_code != "no_saved_session":
		_set_status(response.message)
	_refresh_account_view()


func _on_session_changed(_snapshot: Dictionary) -> void:
	_refresh_account_view()


func _on_token_store_warning(message: String) -> void:
	if not message.is_empty():
		_set_status(message)


func _refresh_account_view() -> void:
	if _client == null:
		return
	var snapshot := _client.get_session_snapshot()
	var connected := bool(snapshot.get("authenticated", false))
	var linked_app_connected := bool(snapshot.get("linked_app_authenticated", false))
	var api_key_connected := bool(snapshot.get("api_key_authenticated", false))
	_email_input.visible = not connected
	_password_input.visible = not connected
	_primary_button.visible = not connected
	_mode_button.visible = not connected and allow_signup
	_challenge_box.visible = not connected and _signup_mode
	_sign_out_button.visible = linked_app_connected
	_description_label.visible = not connected
	_title_label.text = title_text if not connected else connected_title_text
	if connected:
		var account: Variant = snapshot.get("user")
		if linked_app_connected and account is Dictionary and not str(account.get("email", "")).is_empty():
			var account_status := signed_in_as_status_format.format({"email": str(account["email"])})
			if not _client.token_storage_warning.is_empty():
				account_status += "\n" + _client.token_storage_warning
			_set_status(account_status)
		elif api_key_connected:
			_set_status(api_key_status_text)
		elif not _client.token_storage_warning.is_empty():
			_set_status(_client.token_storage_warning)
		else:
			_set_status(connected_status_text)
	elif _signup_mode:
		_title_label.text = signup_title_text


func _set_busy(busy: bool, status: String = "") -> void:
	_primary_button.disabled = busy
	_mode_button.disabled = busy
	_sign_out_button.disabled = busy
	_email_input.editable = not busy
	_password_input.editable = not busy
	_answer_input.editable = not busy
	if not status.is_empty():
		_set_status(status)


func _set_status(status: String) -> void:
	if _status_label != null:
		_status_label.text = status
