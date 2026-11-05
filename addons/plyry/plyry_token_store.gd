@tool
class_name PlyryTokenStore
extends Resource

## Optional app-owned storage for a rotating refresh token.
## The default implementation deliberately stores nothing.


func load_refresh_token() -> String:
	return ""


func save_refresh_token(_refresh_token: String) -> bool:
	return false


func clear_refresh_token() -> bool:
	return false
