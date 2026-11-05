@tool
class_name PlyryClient
extends Node

## Framework-neutral Node client for the Plyry Public API v1.
## Add one instance to the scene tree. Every request owns its own HTTPRequest node,
## so separate calls can run concurrently.

signal session_changed(snapshot: Dictionary)
signal token_store_warning(message: String)
const DEFAULT_API_BASE_URL := "https://plyry.com/v1"
const DEFAULT_SCOPES := ["account:read", "generation:create", "generation:read"]
const WALLET_SCOPES := ["wallet:read", "wallet:topup"]
const CONVERSION_SCOPES := ["conversion:create", "conversion:read"]
const MAX_REFERENCE_FILES := 7
const MAX_REFERENCE_TOTAL_BYTES := 80 * 1024 * 1024
const MAX_REFERENCE_NON_VIDEO_BYTES := 25 * 1024 * 1024
const MAX_REFERENCE_VIDEO_BYTES := 50 * 1024 * 1024
const MAX_CONVERSION_PCF_BYTES := 80 * 1024 * 1024
const MAX_CONVERSION_CATALOG_BYTES := 20 * 1024 * 1024
const MAX_ERROR_BODY_BYTES := 1024 * 1024

@export var api_base_url: String = DEFAULT_API_BASE_URL
@export var app_name: String = "Plyry Godot App"
@export var scopes: PackedStringArray = PackedStringArray(["account:read", "generation:create", "generation:read"])
@export_range(1.0, 300.0, 1.0) var request_timeout_seconds: float = 60.0
@export_range(1.0, 1800.0, 1.0) var upload_timeout_seconds: float = 300.0
@export_range(0.0, 1800.0, 1.0) var download_timeout_seconds: float = 0.0
@export_range(-1, 536870912, 1048576) var response_body_size_limit: int = -1
@export var token_store: PlyryTokenStore

## Set this at runtime only for a trusted server process. Never export a game
## client or public web build containing a secret API key.
var api_key: String = ""
var configuration_error: String = ""
var token_storage_warning: String = ""

var _base_url: String = ""
var _access_token: String = ""
var _refresh_token: String = ""
var _access_token_expires_at_msec: int = 0
var _granted_scopes: PackedStringArray = PackedStringArray()
var _account: Dictionary = {}
var _linked_app: Dictionary = {}
var _session_revision: int = 0
var _authentication_attempt: int = 0
var _refresh_in_flight: bool = false
var _last_refresh_response: PlyryApiResponse

signal _refresh_completed(response: PlyryApiResponse)


func _ready() -> void:
	add_to_group("plyry_client")
	_base_url = normalize_api_base_url(api_base_url)
	if _base_url.is_empty():
		configuration_error = "Use an absolute HTTPS URL for the Plyry API. HTTP is allowed only on localhost."


func get_session_snapshot() -> Dictionary:
	var api_key_authenticated := not api_key.strip_edges().is_empty()
	var linked_app_authenticated := not _access_token.is_empty() or not _refresh_token.is_empty()
	return {
		"authenticated": linked_app_authenticated or api_key_authenticated,
		"linked_app_authenticated": linked_app_authenticated,
		"api_key_authenticated": api_key_authenticated,
		"auth_method": "api_key" if api_key_authenticated else ("linked_app" if linked_app_authenticated else "none"),
		"user": _account.duplicate(true) if not _account.is_empty() else null,
		"linked_app": _linked_app.duplicate(true) if not _linked_app.is_empty() else null,
		"scopes": Array(_granted_scopes),
		"token_storage_warning": token_storage_warning,
	}


func has_scope(scope: String) -> bool:
	return _granted_scopes.has(scope)


func create_signup_challenge(email: String) -> PlyryApiResponse:
	_authentication_attempt += 1
	return await _request_json("/auth/signup/challenges", HTTPClient.METHOD_POST, {"email": email.strip_edges()}, false)


func sign_in(email: String, password: String, requested_scopes: PackedStringArray = PackedStringArray()) -> PlyryApiResponse:
	var scopes_to_request := _choose_scopes(requested_scopes)
	var payload := _auth_payload(email, password, scopes_to_request)
	return await _authenticate("/auth/login", payload, scopes_to_request)


func sign_up(email: String, password: String, signup_challenge: String, answer: String, requested_scopes: PackedStringArray = PackedStringArray()) -> PlyryApiResponse:
	var scopes_to_request := _choose_scopes(requested_scopes)
	var payload := _auth_payload(email, password, scopes_to_request)
	payload["signup_challenge"] = signup_challenge
	payload["answer"] = answer
	return await _authenticate("/auth/signup", payload, scopes_to_request)


func refresh_session() -> PlyryApiResponse:
	return await _refresh_access_token()


func restore_session() -> PlyryApiResponse:
	if _refresh_token.is_empty() and token_store != null:
		_refresh_token = token_store.load_refresh_token().strip_edges()
	if _refresh_token.is_empty():
		return _local_error(401, "no_saved_session", "No saved Plyry session is available.")
	var refreshed := await _refresh_access_token()
	if not refreshed.ok:
		return refreshed
	if not has_scope("account:read"):
		return refreshed
	return await get_me()


func sign_out() -> PlyryApiResponse:
	var token_to_revoke := _refresh_token
	_authentication_attempt += 1
	_session_revision += 1
	_clear_memory_session()
	_clear_stored_refresh_token()
	_emit_session_changed()
	if token_to_revoke.is_empty():
		var local_result := PlyryApiResponse.new()
		local_result.status_code = 200
		local_result.data = {"ok": true}
		return local_result
	return await _request_json("/auth/revoke", HTTPClient.METHOD_POST, {"refresh_token": token_to_revoke}, false)


func request_json(path: String, method: int = HTTPClient.METHOD_GET, payload: Variant = null, authenticated: bool = true, extra_headers: PackedStringArray = PackedStringArray()) -> PlyryApiResponse:
	return await _request_json(path, method, payload, authenticated, false, extra_headers)


func request_bytes(path: String, method: int = HTTPClient.METHOD_GET, body: PackedByteArray = PackedByteArray(), content_type: String = "", authenticated: bool = true, extra_headers: PackedStringArray = PackedStringArray(), download_to_path: String = "") -> PlyryApiResponse:
	return await _request_with_auth(path, method, body, content_type, authenticated, extra_headers, true, download_to_path, false)


func get_openapi_specification() -> PlyryApiResponse:
	return await request_json("/openapi.json", HTTPClient.METHOD_GET, null, false)


func get_models() -> PlyryApiResponse:
	return await request_json("/models", HTTPClient.METHOD_GET, null, false)


func get_me() -> PlyryApiResponse:
	var response := await request_json("/me")
	if response.ok and response.data is Dictionary and response.data.get("user", null) is Dictionary:
		_account = response.data["user"].duplicate(true)
		_emit_session_changed()
	return response


func get_wallet() -> PlyryApiResponse:
	return await request_json("/wallet")


func get_wallet_ledger(page: int = 1) -> PlyryApiResponse:
	return await request_json("/wallet/ledger?page=" + str(maxi(page, 1)))


func get_payment_config() -> PlyryApiResponse:
	return await request_json("/payments/config")


func quote_generation(input: Dictionary) -> PlyryApiResponse:
	return await request_json("/quotes", HTTPClient.METHOD_POST, input)


func create_generation(input: Dictionary) -> PlyryApiResponse:
	var references_value: Variant = input.get("references", [])
	if not references_value is Array:
		return _local_error(0, "invalid_references", "Generation references must be an array of file dictionaries.")
	var references: Array = references_value
	if references.size() > MAX_REFERENCE_FILES:
		return _local_error(0, "too_many_references", "Plyry accepts at most seven reference files.")
	if references.is_empty():
		var json_input := input.duplicate(true)
		json_input.erase("references")
		return await request_json("/generations", HTTPClient.METHOD_POST, json_input)
	var fields: Dictionary = {}
	for field_name in ["type", "prompt", "model", "quality", "reference_mode", "splat_quality"]:
		if input.has(field_name):
			fields[field_name] = str(input[field_name])
	for input_key in input:
		var field_name := str(input_key)
		if field_name in ["references", "reference_count", "reference_slots[]", "references[]", "queue_options", "reference_text_only"] or fields.has(field_name) or input[input_key] == null:
			continue
		var field_value: Variant = input[input_key]
		fields[field_name] = JSON.stringify(field_value) if field_value is Dictionary or field_value is Array else str(field_value)
	if input.has("queue_options"):
		fields["queue_options"] = JSON.stringify(input["queue_options"])
	if bool(input.get("reference_text_only", false)):
		fields["reference_text_only"] = "1"
	fields["reference_count"] = str(references.size())
	var files: Array[Dictionary] = []
	var used_slots: Dictionary = {}
	var total_reference_bytes := 0
	for index in range(references.size()):
		var reference_value: Variant = references[index]
		if not reference_value is Dictionary:
			return _local_error(0, "invalid_reference", "Each generation reference must be a file dictionary.")
		var reference: Dictionary = reference_value
		var slot := int(reference.get("slot", index + 1))
		if slot < 1 or slot > MAX_REFERENCE_FILES or used_slots.has(slot):
			return _local_error(0, "invalid_reference_slot", "Reference slots must be unique integers from 1 to 7.")
		used_slots[slot] = true
		var mime_type := _safe_content_type(str(reference.get("mime_type", "application/octet-stream")))
		var per_file_limit := MAX_REFERENCE_VIDEO_BYTES if mime_type.to_lower().begins_with("video/") else MAX_REFERENCE_NON_VIDEO_BYTES
		var declared_file_size := _get_file_size(reference)
		if declared_file_size <= 0:
			return _local_error(0, "empty_reference", "A reference file is empty or could not be read.")
		if declared_file_size > per_file_limit:
			return _local_error(0, "reference_too_large", "A reference file exceeds the Plyry size limit for its declared media type.")
		if total_reference_bytes + declared_file_size > MAX_REFERENCE_TOTAL_BYTES:
			return _local_error(0, "references_too_large", "Plyry reference files may not exceed 80 MiB in total.")
		var file_bytes := _get_file_bytes(reference, per_file_limit)
		if file_bytes.is_empty():
			return _local_error(0, "empty_reference", "A reference file is empty or could not be read.")
		if file_bytes.size() != declared_file_size:
			return _local_error(0, "reference_changed", "A reference file changed while Plyry prepared the upload. Retry with a stable copy.")
		total_reference_bytes += file_bytes.size()
		files.append({
			"name": "reference_slots[]",
			"value": str(slot),
		})
		files.append({
			"name": "references[]",
			"filename": _safe_filename(str(reference.get("filename", "reference-%d.bin" % slot))),
			"mime_type": mime_type,
			"data": file_bytes,
		})
	return await _send_multipart("/generations", fields, files)


func list_generations(options: Dictionary = {}) -> PlyryApiResponse:
	var query: PackedStringArray = PackedStringArray()
	for key in ["page", "per_page", "status", "type"]:
		if options.has(key) and str(options[key]) != "":
			query.append(_url_encode(str(key)) + "=" + _url_encode(str(options[key])))
	var path := "/generations"
	if not query.is_empty():
		path += "?" + "&".join(query)
	return await request_json(path)


func get_generation(hash: String) -> PlyryApiResponse:
	return await request_json("/generations/" + _url_encode(hash))


func download_generation_media(hash: String, download_to_path: String = "") -> PlyryApiResponse:
	return await request_bytes("/media/" + _url_encode(hash), HTTPClient.METHOD_GET, PackedByteArray(), "", true, PackedStringArray(), download_to_path)


func download_generation_scene(hash: String, download_to_path: String = "") -> PlyryApiResponse:
	return await request_bytes("/media/" + _url_encode(hash) + "/scene", HTTPClient.METHOD_GET, PackedByteArray(), "", true, PackedStringArray(), download_to_path)


func acknowledge_cached_generation(hash: String, cache_token: String, sha256: String) -> PlyryApiResponse:
	return await request_json("/generations/" + _url_encode(hash) + "/cache", HTTPClient.METHOD_POST, {"cache_token": cache_token, "sha256": sha256})


func create_wallet_topup(input: Dictionary, idempotency_key: String) -> PlyryApiResponse:
	if not is_uuid_v4(idempotency_key):
		return _local_error(0, "invalid_idempotency_key", "Wallet top-ups require a UUID v4 Idempotency-Key.")
	for key in input:
		if str(key) not in ["amount_cents", "billing_country", "payment_method_id", "return_url"]:
			return _local_error(0, "invalid_topup_field", "Top-ups accept only amount_cents, billing_country, payment_method_id, and return_url. Send a provider-tokenized payment method ID, never raw card details.")
	return await request_json("/wallet/topups", HTTPClient.METHOD_POST, input, true, PackedStringArray(["Idempotency-Key: " + idempotency_key]))


func get_wallet_topup_status(request_key: String) -> PlyryApiResponse:
	if not is_uuid_v4(request_key):
		return _local_error(0, "invalid_request_key", "The top-up request key must be a UUID v4.")
	return await request_json("/wallet/topups/requests/" + _url_encode(request_key))


func reconcile_wallet_topup(payment_intent_id: String) -> PlyryApiResponse:
	return await request_json("/wallet/topups/reconcile", HTTPClient.METHOD_POST, {"payment_intent_id": payment_intent_id})


func get_plant3d_to_revit_price() -> PlyryApiResponse:
	return await request_json("/conversions/plant3d-to-revit/price")


func create_plant3d_to_revit_job(pcf: Dictionary, catalog: Dictionary, idempotency_key: String) -> PlyryApiResponse:
	if not is_uuid_v4(idempotency_key):
		return _local_error(0, "invalid_idempotency_key", "Conversion submissions require a UUID v4 Idempotency-Key.")
	if _get_file_size(pcf) > MAX_CONVERSION_PCF_BYTES:
		return _local_error(0, "pcf_too_large", "The PCF file exceeds the 80 MB API limit.")
	if _get_file_size(catalog) > MAX_CONVERSION_CATALOG_BYTES:
		return _local_error(0, "catalog_too_large", "The fabrication catalog exceeds the 20 MB API limit.")
	var pcf_bytes := _get_file_bytes(pcf, MAX_CONVERSION_PCF_BYTES)
	var catalog_bytes := _get_file_bytes(catalog, MAX_CONVERSION_CATALOG_BYTES)
	if pcf_bytes.is_empty() or catalog_bytes.is_empty():
		return _local_error(0, "missing_conversion_file", "Both the PCF and fabrication catalog files are required.")
	var files: Array[Dictionary] = [
		{"name": "pcf", "filename": _safe_filename(str(pcf.get("filename", "plant3d.pcf"))), "mime_type": "application/octet-stream", "data": pcf_bytes},
		{"name": "catalog", "filename": _safe_filename(str(catalog.get("filename", "fabrication-catalog.json"))), "mime_type": "application/json", "data": catalog_bytes},
	]
	return await _send_multipart("/conversions/plant3d-to-revit/jobs", {}, files, PackedStringArray(["Idempotency-Key: " + idempotency_key]))


func get_plant3d_to_revit_job(hash: String) -> PlyryApiResponse:
	return await request_json("/conversions/plant3d-to-revit/jobs/" + _url_encode(hash))


func search_plant3d_to_revit_buttons(hash: String, options: Dictionary = {}) -> PlyryApiResponse:
	var query: PackedStringArray = PackedStringArray()
	if str(options.get("q", "")) != "":
		query.append("q=" + _url_encode(str(options["q"])))
	if bool(options.get("all", false)):
		query.append("all=1")
	var path := "/conversions/plant3d-to-revit/jobs/" + _url_encode(hash) + "/buttons"
	if not query.is_empty():
		path += "?" + "&".join(query)
	return await request_json(path)


func revise_plant3d_to_revit_mapping(hash: String, mappings: Dictionary) -> PlyryApiResponse:
	return await request_json("/conversions/plant3d-to-revit/jobs/" + _url_encode(hash) + "/mapping", HTTPClient.METHOD_POST, {"mappings": mappings})


func download_plant3d_to_revit_mapping(hash: String, download_to_path: String = "") -> PlyryApiResponse:
	var path := "/conversions/plant3d-to-revit/jobs/" + _url_encode(hash) + "/download"
	return await request_bytes(path, HTTPClient.METHOD_GET, PackedByteArray(), "", true, PackedStringArray(), download_to_path)


func _authenticate(path: String, payload: Dictionary, requested_scopes: PackedStringArray) -> PlyryApiResponse:
	_authentication_attempt += 1
	var attempt := _authentication_attempt
	var response := await _request_json(path, HTTPClient.METHOD_POST, payload, false, true)
	if not response.ok:
		response.data = _sanitize_value(response.data)
		return response
	if not response.data is Dictionary:
		response.status_code = 502
		response.error_code = "invalid_token_response"
		response.message = "Plyry returned an invalid linked-app session."
		response.data = null
		return response
	var raw: Dictionary = response.data
	var new_access := str(raw.get("access_token", ""))
	var new_refresh := str(raw.get("refresh_token", ""))
	var new_user: Variant = raw.get("user", null)
	var new_linked_app: Variant = raw.get("linked_app", null)
	if new_access.is_empty() or new_refresh.is_empty() or not new_user is Dictionary or not new_linked_app is Dictionary:
		if not new_refresh.is_empty():
			await _revoke_refresh_token(new_refresh)
		response.status_code = 502
		response.error_code = "invalid_token_response"
		response.message = "Plyry returned an incomplete linked-app session."
		response.data = _sanitize_value(raw)
		return response
	if attempt != _authentication_attempt:
		await _revoke_refresh_token(new_refresh)
		return _local_error(409, "session_changed", "The Plyry session changed while signing in. Retry the request.")
	_session_revision += 1
	_access_token = new_access
	_refresh_token = new_refresh
	_access_token_expires_at_msec = Time.get_ticks_msec() + clampi(int(raw.get("expires_in", 900)), 60, 86400) * 1000
	_granted_scopes = _parse_scopes(raw.get("scopes", requested_scopes), requested_scopes)
	_account = new_user.duplicate(true)
	_linked_app = new_linked_app.duplicate(true)
	_save_stored_refresh_token(_refresh_token)
	response.data = _sanitize_value(raw)
	_emit_session_changed()
	return response


func _refresh_access_token() -> PlyryApiResponse:
	if _refresh_in_flight:
		await _refresh_completed
		return _last_refresh_response
	if _refresh_token.is_empty():
		return _local_error(401, "missing_refresh_token", "Sign in to your Plyry account first.")
	_refresh_in_flight = true
	var expected_revision := _session_revision
	var old_token := _refresh_token
	var response := await _request_json("/auth/refresh", HTTPClient.METHOD_POST, {"refresh_token": old_token}, false, true)
	if expected_revision != _session_revision or old_token != _refresh_token:
		var replacement := str(response.data.get("refresh_token", "")) if response.data is Dictionary else ""
		if not replacement.is_empty():
			await _revoke_refresh_token(replacement)
		response = _local_error(409, "session_changed", "The Plyry session changed while its token was refreshing.")
	elif response.ok and response.data is Dictionary:
		var raw: Dictionary = response.data
		var next_access := str(raw.get("access_token", ""))
		var next_refresh := str(raw.get("refresh_token", ""))
		if next_access.is_empty() or next_refresh.is_empty():
			response = _local_error(502, "invalid_token_response", "Plyry returned an invalid token refresh response. Sign in again.")
			_session_revision += 1
			_clear_memory_session()
			_clear_stored_refresh_token()
			_emit_session_changed()
		else:
			_access_token = next_access
			_refresh_token = next_refresh
			_access_token_expires_at_msec = Time.get_ticks_msec() + clampi(int(raw.get("expires_in", 900)), 60, 86400) * 1000
			_granted_scopes = _parse_scopes(raw.get("scopes", _granted_scopes), _granted_scopes)
			if raw.get("linked_app", null) is Dictionary:
				_linked_app = raw["linked_app"].duplicate(true)
			_save_stored_refresh_token(_refresh_token)
			response.data = _sanitize_value(raw)
	elif response.status_code == 401 and response.error_code in ["invalid_refresh_token", "refresh_token_expired", "refresh_token_revoked"]:
		_session_revision += 1
		_clear_memory_session()
		_clear_stored_refresh_token()
		_emit_session_changed()
	if response.ok and not response.data is Dictionary:
		response = _local_error(502, "invalid_token_response", "Plyry returned an invalid token refresh response. Sign in again.")
		_session_revision += 1
		_clear_memory_session()
		_clear_stored_refresh_token()
		_emit_session_changed()
	if not response.ok:
		response.data = _sanitize_value(response.data)
	_last_refresh_response = response
	_refresh_in_flight = false
	_refresh_completed.emit(response)
	return response


func _request_json(path: String, method: int, payload: Variant, authenticated: bool, allow_sensitive_response: bool = false, extra_headers: PackedStringArray = PackedStringArray()) -> PlyryApiResponse:
	var body := PackedByteArray()
	var content_type := ""
	if payload != null:
		body = JSON.stringify(payload).to_utf8_buffer()
		content_type = "application/json; charset=utf-8"
	return await _request_with_auth(path, method, body, content_type, authenticated, extra_headers, false, "", allow_sensitive_response)


func _request_with_auth(path: String, method: int, body: PackedByteArray, content_type: String, authenticated: bool, extra_headers: PackedStringArray, binary_response: bool, download_to_path: String, allow_sensitive_response: bool) -> PlyryApiResponse:
	if not configuration_error.is_empty():
		return _local_error(0, "invalid_configuration", configuration_error)
	if not _is_safe_api_path(path):
		return _local_error(0, "invalid_path", "Plyry request paths must stay within the configured API origin.")
	var header_error := _validate_extra_headers(extra_headers)
	if not header_error.is_empty():
		return _local_error(0, "invalid_header", header_error)
	if not is_inside_tree():
		return _local_error(0, "client_not_in_tree", "Add PlyryClient to the active scene tree before making API requests.")
	var starting_revision := _session_revision
	if authenticated and api_key.strip_edges().is_empty() and not _refresh_token.is_empty() and ( _access_token.is_empty() or _access_token_expires_at_msec <= Time.get_ticks_msec() + 30000):
		var refreshed := await _refresh_access_token()
		if not refreshed.ok:
			return refreshed
	if authenticated and api_key.strip_edges().is_empty() and _access_token.is_empty():
		return _local_error(401, "missing_access_token", "Sign in to your Plyry account before making this request.")
	if authenticated and starting_revision != _session_revision:
		return _local_error(409, "session_changed", "The Plyry session changed while preparing this request. Retry it.")
	var response := await _send_request(path, method, body, content_type, authenticated, extra_headers, binary_response, download_to_path, allow_sensitive_response, starting_revision)
	if authenticated and starting_revision != _session_revision:
		return _local_error(409, "session_changed", "The Plyry session changed while this request was in progress.")
	if authenticated and response.status_code == 401 and api_key.strip_edges().is_empty() and not _refresh_token.is_empty():
		var retry_refresh := await _refresh_access_token()
		if retry_refresh.ok and starting_revision == _session_revision:
			response = await _send_request(path, method, body, content_type, true, extra_headers, binary_response, download_to_path, allow_sensitive_response, starting_revision)
		if starting_revision != _session_revision:
			return _local_error(409, "session_changed", "The Plyry session changed while this request was in progress.")
	return response


func _send_request(path: String, method: int, body: PackedByteArray, content_type: String, authenticated: bool, extra_headers: PackedStringArray, binary_response: bool, download_to_path: String, allow_sensitive_response: bool, expected_session_revision: int) -> PlyryApiResponse:
	var response := PlyryApiResponse.new()
	var staged_download_path := ""
	if not download_to_path.is_empty():
		staged_download_path = _create_download_staging_path(download_to_path)
		if staged_download_path.is_empty():
			return _local_error(0, "download_path_unavailable", "Godot could not create a temporary path beside the requested download.")
	var request_node := HTTPRequest.new()
	if not staged_download_path.is_empty():
		request_node.timeout = download_timeout_seconds
	elif content_type.begins_with("multipart/form-data;"):
		request_node.timeout = upload_timeout_seconds
	else:
		request_node.timeout = request_timeout_seconds
	request_node.body_size_limit = response_body_size_limit
	request_node.use_threads = true
	request_node.max_redirects = 0
	if not staged_download_path.is_empty():
		request_node.download_file = staged_download_path
	add_child(request_node)
	var request_headers := PackedStringArray(["Accept: " + ("*/*" if binary_response else "application/json")])
	if not content_type.is_empty():
		request_headers.append("Content-Type: " + content_type)
	var token := api_key.strip_edges() if not api_key.strip_edges().is_empty() else _access_token
	if authenticated and not token.is_empty():
		request_headers.append("Authorization: Bearer " + token)
	for header in extra_headers:
		request_headers.append(header)
	var start_error := request_node.request_raw(_base_url + path, request_headers, method, body)
	if start_error != OK:
		request_node.queue_free()
		_remove_file(staged_download_path)
		response.transport_result = HTTPRequest.RESULT_REQUEST_FAILED
		response.error_code = "request_start_failed"
		response.message = "Godot could not start the HTTP request (error %d)." % start_error
		return response
	var completion: Array = await request_node.request_completed
	request_node.queue_free()
	response.transport_result = int(completion[0])
	response.status_code = int(completion[1])
	response.headers = completion[2]
	var received_body: PackedByteArray = completion[3] if staged_download_path.is_empty() else PackedByteArray()
	if authenticated and expected_session_revision != _session_revision:
		_remove_file(staged_download_path)
		return _local_error(409, "session_changed", "The Plyry session changed while this request was in progress.")
	if response.transport_result != HTTPRequest.RESULT_SUCCESS:
		_remove_file(staged_download_path)
		if response.transport_result == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
			response.error_code = "redirect_blocked"
			response.message = "Plyry redirected this request. Configure the final API URL; PlyryClient does not follow redirects with credentials."
		elif response.transport_result in [HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR]:
			response.error_code = "download_write_failed"
			response.message = "Godot could not write the download to its temporary file (HTTP result %d)." % response.transport_result
		else:
			response.error_code = "network_error"
			response.message = "The request could not be completed (Godot HTTP result %d)." % response.transport_result
		return response
	var is_http_error := response.status_code < 200 or response.status_code >= 300
	if is_http_error and not staged_download_path.is_empty():
		received_body = _read_file_prefix(staged_download_path, MAX_ERROR_BODY_BYTES)
	if not received_body.is_empty() and (not binary_response or is_http_error):
		var parser := JSON.new()
		var parse_result := parser.parse(received_body.get_string_from_utf8())
		if parse_result == OK:
			response.data = parser.data
		elif not binary_response:
			response.error_code = "invalid_json"
			response.message = "Plyry returned a response that could not be read as JSON."
	if not binary_response and response.data is Dictionary and response.data.get("ok", true) == false:
		response.error_code = str(response.data.get("error", "api_error"))
		response.message = str(response.data.get("message", "Plyry API request failed."))
	if is_http_error:
		if response.data is Dictionary:
			response.error_code = str(response.data.get("error", response.error_code if not response.error_code.is_empty() else "http_error"))
			response.message = str(response.data.get("message", "Plyry API request failed with HTTP %d." % response.status_code))
		else:
			response.error_code = "http_error"
			response.message = "Plyry API request failed with HTTP %d." % response.status_code
	if not staged_download_path.is_empty():
		if is_http_error:
			_remove_file(staged_download_path)
		else:
			var finalize_error := _finalize_download(staged_download_path, download_to_path)
			if finalize_error != OK:
				_remove_file(staged_download_path)
				response.error_code = "download_finalize_failed"
				response.message = "The response downloaded, but Godot could not move it into the requested destination (error %d)." % finalize_error
			else:
				response.download_path = download_to_path
	elif binary_response and not is_http_error:
		response.body = received_body
	if not allow_sensitive_response:
		response.data = _sanitize_value(response.data)
	return response


func _send_multipart(path: String, fields: Dictionary, files: Array[Dictionary], extra_headers: PackedStringArray = PackedStringArray()) -> PlyryApiResponse:
	var crypto := Crypto.new()
	var random_bytes := crypto.generate_random_bytes(18)
	if random_bytes.size() != 18:
		return _local_error(0, "secure_random_unavailable", "Godot could not create a secure multipart boundary.")
	var boundary := "plyry-" + random_bytes.hex_encode()
	var data := PackedByteArray()
	for key in fields:
		if not _is_safe_multipart_field_name(str(key)):
			return _local_error(0, "invalid_multipart_field", "Multipart field names must use letters, numbers, underscores, dots, brackets, or hyphens.")
		_append_text(data, "--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % [boundary, key, str(fields[key])])
	for file_part in files:
		var field_name := str(file_part.get("name", "file"))
		if not _is_safe_multipart_field_name(field_name):
			return _local_error(0, "invalid_multipart_field", "Multipart field names must use letters, numbers, underscores, dots, brackets, or hyphens.")
		var filename := _safe_filename(str(file_part.get("filename", "upload.bin")))
		var mime_type := _safe_content_type(str(file_part.get("mime_type", "application/octet-stream")))
		_append_text(data, "--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n" % [boundary, field_name, filename, mime_type])
		data.append_array(file_part.get("data", PackedByteArray()))
		_append_text(data, "\r\n")
	_append_text(data, "--%s--\r\n" % boundary)
	return await _request_with_auth(path, HTTPClient.METHOD_POST, data, "multipart/form-data; boundary=" + boundary, true, extra_headers, false, "", false)


func _auth_payload(email: String, password: String, scopes_to_request: PackedStringArray) -> Dictionary:
	return {
		"email": email.strip_edges(),
		"password": password,
		"app_name": app_name.strip_edges() if not app_name.strip_edges().is_empty() else "Plyry Godot App",
		"scopes": scopes_to_request,
	}


func _choose_scopes(requested: PackedStringArray) -> PackedStringArray:
	return requested.duplicate() if not requested.is_empty() else scopes.duplicate()


func _parse_scopes(value: Variant, fallback: PackedStringArray) -> PackedStringArray:
	var parsed := PackedStringArray()
	if value is PackedStringArray:
		return value.duplicate()
	if value is Array:
		for scope in value:
			parsed.append(str(scope))
		return parsed
	return fallback.duplicate()


func _emit_session_changed() -> void:
	session_changed.emit(get_session_snapshot())


func _clear_memory_session() -> void:
	_access_token = ""
	_refresh_token = ""
	_access_token_expires_at_msec = 0
	_granted_scopes = PackedStringArray()
	_account.clear()
	_linked_app.clear()


func _save_stored_refresh_token(token: String) -> void:
	if token_store == null:
		return
	if not token_store.save_refresh_token(token):
		_set_token_storage_warning("The Plyry session is active, but the configured token store could not save it.")
	else:
		_set_token_storage_warning("")


func _clear_stored_refresh_token() -> void:
	if token_store == null:
		return
	if not token_store.clear_refresh_token():
		_set_token_storage_warning("The Plyry session ended, but the configured token store could not clear it.")
	else:
		_set_token_storage_warning("")


func _set_token_storage_warning(message: String) -> void:
	token_storage_warning = message
	token_store_warning.emit(message)


func _revoke_refresh_token(token: String) -> void:
	if token.is_empty() or not is_inside_tree():
		return
	await _request_json("/auth/revoke", HTTPClient.METHOD_POST, {"refresh_token": token}, false)


func _get_file_bytes(file_info: Dictionary, max_bytes: int = -1) -> PackedByteArray:
	var bytes: Variant = file_info.get("data", PackedByteArray())
	if bytes is PackedByteArray:
		return PackedByteArray() if max_bytes >= 0 and bytes.size() > max_bytes else bytes
	var file_path := str(file_info.get("path", ""))
	if file_path.is_empty():
		return PackedByteArray()
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var file_size := file.get_length()
	if file_size <= 0 or (max_bytes >= 0 and file_size > max_bytes):
		file.close()
		return PackedByteArray()
	var result := file.get_buffer(file_size)
	file.close()
	return result


func _read_file_prefix(file_path: String, max_bytes: int) -> PackedByteArray:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var read_size := mini(file.get_length(), max_bytes)
	var result := file.get_buffer(read_size)
	file.close()
	return result


func _create_download_staging_path(destination_path: String) -> String:
	var crypto := Crypto.new()
	var random_bytes := crypto.generate_random_bytes(12)
	if random_bytes.size() != 12:
		return ""
	var candidate := destination_path + ".plyry-" + random_bytes.hex_encode() + ".part"
	return "" if FileAccess.file_exists(candidate) else candidate


func _finalize_download(staging_path: String, destination_path: String) -> int:
	var absolute_staging_path := ProjectSettings.globalize_path(staging_path)
	var absolute_destination_path := ProjectSettings.globalize_path(destination_path)
	if not FileAccess.file_exists(absolute_staging_path):
		return ERR_FILE_NOT_FOUND
	return DirAccess.rename_absolute(absolute_staging_path, absolute_destination_path)


func _remove_file(file_path: String) -> void:
	if file_path.is_empty():
		return
	var absolute_path := ProjectSettings.globalize_path(file_path)
	if FileAccess.file_exists(absolute_path):
		DirAccess.remove_absolute(absolute_path)


func _get_file_size(file_info: Dictionary) -> int:
	var bytes: Variant = file_info.get("data", PackedByteArray())
	if bytes is PackedByteArray:
		return bytes.size()
	var file_path := str(file_info.get("path", ""))
	if file_path.is_empty():
		return -1
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return -1
	var file_size := file.get_length()
	file.close()
	return file_size


func _local_error(status: int, code: String, error_message: String) -> PlyryApiResponse:
	var response := PlyryApiResponse.new()
	response.status_code = status
	response.error_code = code
	response.message = error_message
	response.data = {"ok": false, "error": code, "message": error_message}
	return response


func _sanitize_value(value: Variant) -> Variant:
	if value is Dictionary:
		var cleaned: Dictionary = {}
		for key in value:
			var normalized_key := str(key).to_lower().replace("-", "_")
			if normalized_key in ["access_token", "refresh_token", "api_key", "authorization", "password", "passphrase", "secret", "client_secret", "payment_method_id"]:
				continue
			cleaned[key] = _sanitize_value(value[key])
		return cleaned
	if value is Array:
		var cleaned_array: Array = []
		for item in value:
			cleaned_array.append(_sanitize_value(item))
		return cleaned_array
	return value


func _is_safe_api_path(path: String) -> bool:
	if not path.begins_with("/") or path.begins_with("//") or path.contains("\\") or path.contains("\r") or path.contains("\n") or path.contains("#") or path.contains(" ") or path.contains("://"):
		return false
	for byte in path.to_utf8_buffer():
		if byte < 32 or byte == 127:
			return false
	var query_index := path.find("?")
	var route_path := path if query_index < 0 else path.substr(0, query_index)
	var route_segments := route_path.split("/", true)
	for index in range(route_segments.size()):
		var segment := route_segments[index]
		if index > 0 and index < route_segments.size() - 1 and segment.is_empty():
			return false
		var decoded_segment := segment.uri_decode()
		if decoded_segment in [".", ".."] or decoded_segment.contains("/") or decoded_segment.contains("\\") or decoded_segment.contains("\u0000"):
			return false
	return true


func _validate_extra_headers(extra_headers: PackedStringArray) -> String:
	var header_name_pattern := RegEx.new()
	header_name_pattern.compile("^[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
	var blocked_headers := ["authorization", "proxy-authorization", "host", "content-length", "transfer-encoding", "connection", "keep-alive", "te", "trailer", "upgrade", "content-type", "origin", "referer", "cookie", "cookie2"]
	for header in extra_headers:
		for byte in header.to_utf8_buffer():
			if byte < 32 or byte == 127:
				return "Extra headers cannot contain control characters."
		var separator := header.find(":")
		if separator <= 0:
			return "Extra headers must use a valid Header-Name: value format."
		var header_name := header.substr(0, separator).strip_edges()
		if header_name_pattern.search(header_name) == null:
			return "An extra header has an invalid name."
		if header_name.to_lower() in blocked_headers:
			return "The %s header is managed by PlyryClient or the HTTP platform and cannot be overridden." % header_name
	return ""


func _url_encode(value: String) -> String:
	return value.uri_encode()


func _safe_filename(value: String) -> String:
	var safe := value.get_file().replace("\r", "_").replace("\n", "_").replace("\"", "_")
	return safe if not safe.is_empty() else "upload.bin"


func _safe_content_type(value: String) -> String:
	if value.contains("\r") or value.contains("\n"):
		return "application/octet-stream"
	return value if not value.is_empty() else "application/octet-stream"


func _is_safe_multipart_field_name(value: String) -> bool:
	var field_pattern := RegEx.new()
	field_pattern.compile("^[A-Za-z0-9_.\\[\\]-]+$")
	return field_pattern.search(value) != null


func _append_text(target: PackedByteArray, value: String) -> void:
	target.append_array(value.to_utf8_buffer())


static func create_idempotency_key() -> String:
	var random_bytes := Crypto.new().generate_random_bytes(16)
	if random_bytes.size() != 16:
		return ""
	random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40
	random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80
	var hex := random_bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]


static func is_uuid_v4(value: String) -> bool:
	var expression := RegEx.new()
	expression.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
	return expression.search(value) != null


static func normalize_api_base_url(value: String) -> String:
	var url := value.strip_edges()
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	if url.is_empty() or url.contains("?") or url.contains("#") or url.contains("\\") or url.contains("@") or url.contains(" ") or url.contains("\r") or url.contains("\n"):
		return ""
	for byte in url.to_utf8_buffer():
		if byte < 32 or byte == 127:
			return ""
	var scheme_separator := url.find("://")
	if scheme_separator < 0:
		return ""
	var scheme := url.substr(0, scheme_separator).to_lower()
	if scheme != "https" and scheme != "http":
		return ""
	var remainder := url.substr(scheme_separator + 3)
	var slash_index := remainder.find("/")
	var authority := remainder if slash_index < 0 else remainder.substr(0, slash_index)
	if authority.is_empty():
		return ""
	var authority_pattern := RegEx.new()
	authority_pattern.compile("^(?:[A-Za-z0-9.-]+|\\[[0-9A-Fa-f:]+\\])(?::[0-9]{1,5})?$")
	if authority_pattern.search(authority) == null:
		return ""
	var port := ""
	if authority.begins_with("["):
		var closing_bracket := authority.find("]")
		if closing_bracket + 1 < authority.length():
			port = authority.substr(closing_bracket + 2)
	elif authority.contains(":"):
		port = authority.substr(authority.find(":") + 1)
	if not port.is_empty() and (int(port) < 1 or int(port) > 65535):
		return ""
	var host := authority.to_lower()
	if host.begins_with("["):
		var closing_bracket := host.find("]")
		if closing_bracket < 0:
			return ""
		host = host.substr(0, closing_bracket + 1)
	elif host.contains(":"):
		host = host.substr(0, host.find(":"))
	var local_host := host in ["localhost", "127.0.0.1", "[::1]"]
	if scheme != "https" and not (scheme == "http" and local_host):
		return ""
	var path := "" if slash_index < 0 else remainder.substr(slash_index)
	while path.ends_with("/"):
		path = path.substr(0, path.length() - 1)
	var base_segments := path.split("/", true)
	for index in range(base_segments.size()):
		var segment := base_segments[index]
		if index > 0 and index < base_segments.size() - 1 and segment.is_empty():
			return ""
		var decoded_segment := segment.uri_decode()
		if decoded_segment in [".", ".."] or decoded_segment.contains("/") or decoded_segment.contains("\\"):
			return ""
	if path.to_lower().ends_with("/v1"):
		path = path.substr(0, path.length() - 3).trim_suffix("/")
	return scheme + "://" + authority + path + "/v1"
