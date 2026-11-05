# Plyry API for Godot

A standalone Godot 4 addon for calling the Plyry Public API v1. API requests, sign-in, signup, account linking, and session refresh happen directly over HTTPS. The addon does not embed or load Plyry website pages.

The client is independent from the optional account panel. Use the headless `PlyryClient` methods with your own UI, or add `PlyryAccountPanel` for a simple local sign-in and signup flow.

## Install

Open this repository root as a Godot project to run the included example. To install the addon elsewhere, copy `addons/plyry/` into your project's `addons/plyry/` folder. In **Project → Project Settings → Plugins**, enable **Plyry API**.

Add a `PlyryClient` node to a persistent scene. The node must be inside the active scene tree before making requests. The default service is `https://plyry.com/v1`; set `api_base_url` and `app_name` in the Inspector as needed.

The default `scopes` request account and generation access. Add `wallet:read` and `wallet:topup` when the app needs wallet features, or `conversion:create` and `conversion:read` when it needs conversion endpoints. Request only the scopes the app uses.

## Call the API

Most methods are asynchronous and return a `PlyryApiResponse`:

```gdscript
extends Node

@onready var plyry: PlyryClient = $PlyryClient

func _ready() -> void:
	var catalog := await plyry.get_models()
	if catalog.ok:
		print(catalog.data.get("models", []))
	else:
		push_warning("Plyry: %s (%s)" % [catalog.message, catalog.error_code])

func sign_in(email: String, password: String) -> void:
	var response := await plyry.sign_in(email, password)
	if response.ok:
		print("Connected account: ", plyry.get_session_snapshot().get("user"))
```

`PlyryApiResponse` exposes `ok`, `status_code`, `error_code`, `message`, parsed `data`, response `headers`, and `body` bytes for successful binary responses. JSON is available through `data`; its raw response bytes are discarded so authentication tokens are not accidentally exposed. Binary downloads also expose `download_path` when you pass a destination path. Downloads go to a temporary sibling file first and replace the destination only after a successful response, so failed transfers do not leave a partial result. Use `response.get_header("X-Plyry-Media-SHA256")` and `response.get_header("X-Plyry-Cache-Token")` for media verification and cache acknowledgments.

### Current API methods

- Authentication: `create_signup_challenge`, `sign_in`, `sign_up`, `refresh_session`, `restore_session`, and `sign_out`.
- Public API information: `get_openapi_specification`, `get_models`.
- Account and wallet: `get_me`, `get_wallet`, `get_wallet_ledger`, `get_payment_config`, `create_wallet_topup`, `get_wallet_topup_status`, and `reconcile_wallet_topup`.
- Generation: `quote_generation`, `create_generation`, `list_generations`, `get_generation`, `download_generation_media`, `download_generation_scene`, and `acknowledge_cached_generation`.
- Plant 3D to Revit API: `get_plant3d_to_revit_price`, `create_plant3d_to_revit_job`, `get_plant3d_to_revit_job`, `search_plant3d_to_revit_buttons`, `revise_plant3d_to_revit_mapping`, and `download_plant3d_to_revit_mapping`.
- `request_json` and `request_bytes` for other routes. The live contract is [OpenAPI v1](https://plyry.com/v1/openapi.json), with plain-language [API documentation](https://plyry.com/docs/api).

Use `extra_headers` for API-specific headers such as `Idempotency-Key`. Authorization, origin, content-type, and HTTP framing headers are managed by the client or platform and cannot be overridden.

Use a dictionary for generation data. Text-only requests use JSON. For multipart references, each item in `references` is a dictionary with `data` (a `PackedByteArray`) or `path`, and optional `filename`, `mime_type`, and `slot`:

```gdscript
var result := await plyry.create_generation({
	"type": "image",
	"model": "public-model-id",
	"prompt": "A quiet greenhouse at sunrise",
	"quality": "full",
	"queue_options": {"generation": {"aspect": "1:1"}},
	"references": [{
		"path": "user://reference.png",
		"filename": "reference.png",
		"mime_type": "image/png",
		"slot": 1,
	}],
})
```

Plyry supports up to seven reference files. Slots must be unique values from 1 through 7. The client enforces the service's current per-file and 80 MiB aggregate reference limits before reading files into an upload. Additional generation fields are carried into multipart form data; arrays and dictionaries are JSON-encoded. `create_plant3d_to_revit_job` accepts two file dictionaries (`pcf` and `catalog`) in the same `data` or `path` format.

For large downloads, pass a local destination path to a download method. Godot writes the response there while transferring it instead of retaining the complete file in memory. Multipart uploads use `upload_timeout_seconds` (300 seconds by default). Downloads use `download_timeout_seconds`, which defaults to `0` (disabled) for large transfers; set a finite limit if the application needs one:

```gdscript
var download := await plyry.download_generation_media(job_hash, "user://generated/result.glb")
if download.ok:
	var digest := download.get_header("X-Plyry-Media-SHA256")
	var cache_token := download.get_header("X-Plyry-Cache-Token")
	if not digest.is_empty() and not cache_token.is_empty():
		await plyry.acknowledge_cached_generation(job_hash, cache_token, digest)
```

## Account panel customization

The optional `PlyryAccountPanel` is an ordinary Godot `PanelContainer`. It creates local Controls for sign-in, the signup challenge, and sign-out. It never opens a Plyry login page. The form can preview in the editor; API requests and client connections only start when the game runs.

- Assign a Godot `Theme` with the `custom_theme` property to change colors, fonts, styles, and control dimensions. A sample theme is in `addons/plyry/themes/plyry_account_panel_theme.tres`.
- Change the titles, status text, descriptions, signup prompts, input placeholders, and button labels through exported properties.
- Set `client_path` to your `PlyryClient` node, or leave it empty to discover a client in the `plyry_client` group.
- Hide signup by setting `allow_signup` to `false`.
- For a fully custom layout, omit the panel and call `PlyryClient` from your own controls. Connect to `session_changed` to keep the UI updated.

The root sample project runs `examples/basic/main.tscn` and shows the optional panel and its theme. Copy the scene and theme into your own project and edit them as needed.

## Authentication and token safety

Sign-in uses the API's direct email/password endpoint and creates a linked-app entry for the user's account. This is not OAuth or OpenID Connect. The API flow does not add email verification or account recovery. A user can revoke a linked app from their Plyry account.

Access and refresh tokens stay in memory by default. The addon never writes credentials automatically. To restore a session between launches, subclass `PlyryTokenStore` and implement secure platform storage for the rotating refresh token. Do not use a plain config file or `user://` text file for long-lived credentials. API-key access is available by setting `api_key` at runtime for trusted server-side use; never put a secret key into a game, desktop client, or public web build. `get_session_snapshot()` includes `auth_method`, `linked_app_authenticated`, and `api_key_authenticated` so your UI can distinguish linked accounts from server API-key access.

Wallet top-ups require a UUID v4 idempotency key. Create one with `PlyryClient.create_idempotency_key()` and reuse that same key only when retrying the same attempt. Payment methods must be tokenized by the configured payment provider; send only the provider's `payment_method_id` to Plyry, never a card number or security code.

`GET /payments/return` is an HTML browser-navigation endpoint, not a JSON API call. Use the payment provider's action flow and its return URL only when implementing top-ups; the addon does not load a Plyry sign-in or wallet page.

## Websites and Godot Web exports

Godot Web requests run from the exported website and are subject to browser CORS. Sign in from the deployed origin so the linked app is associated with that website. Do not try to set the browser's `Origin` header yourself. Use HTTPS for production websites. The addon does not need a Plyry website tab, cookie, iframe, or embedded browser. The client does not follow HTTP redirects, which prevents credentials from being forwarded to another host; configure the canonical API URL and use direct API endpoints.

## Godot version and platform notes

The addon targets Godot 4.x and uses built-in `HTTPRequest`, `Crypto`, and Controls. Android exports must include the `INTERNET` permission. Platform-specific TLS, network, browser CORS, and app-store policies still apply. The HTTP client creates one `HTTPRequest` per operation, allowing concurrent API calls.

## License

MIT. See [LICENSE](LICENSE).
