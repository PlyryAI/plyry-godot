@tool
class_name PlyryApiResponse
extends RefCounted

## A single JSON or binary result from the Plyry API.

var status_code: int = 0
var transport_result: int = HTTPRequest.RESULT_SUCCESS
var headers: PackedStringArray = PackedStringArray()
var body: PackedByteArray = PackedByteArray()
var data: Variant = null
var error_code: String = ""
var message: String = ""
var download_path: String = ""

var ok: bool:
	get:
		return transport_result == HTTPRequest.RESULT_SUCCESS and error_code.is_empty() and status_code >= 200 and status_code < 300


func get_header(header_name: String) -> String:
	var sought := header_name.strip_edges().to_lower()
	for header in headers:
		var separator := header.find(":")
		if separator >= 0 and header.substr(0, separator).strip_edges().to_lower() == sought:
			return header.substr(separator + 1).strip_edges()
	return ""


func is_binary() -> bool:
	return not body.is_empty() and data == null
