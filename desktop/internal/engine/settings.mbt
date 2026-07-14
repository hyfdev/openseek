// The host-owned engine endpoint settings: which provider runs use, its
// credentials, and the WSL preference. They live in the host's runtime dir
// (`engine-settings.json`) — never in a client — so a browser page cannot
// leak one host's key to another, and the desktop window and every remote
// page see the same configuration. Clients edit them through the
// `settings.get`/`settings.set` methods and learn about others' edits from
// the `settings.changed` broadcast; runs read them at config time, so a
// change respawns the conversation's engine on its next start (the
// fingerprint covers the resolved values).
//
// File format rules (the versioning contract):
// - `version` is written on every save; a real reshape bumps it and adds a
//   read-side migration. Missing reads as 1.
// - Reads are tolerant: missing fields are defaults, unknown fields are
//   ignored — and preserved verbatim on save (see `update_settings`), so a
//   downgrade's edit never eats a newer build's fields.
// - A file written by a newer version (version above ours) is read
//   best-effort but refused for writing.
// - Saves are atomic: temp file + rename, 0600.

///|
const EngineSettingsVersion = 1

///|
const EngineSettingsFileName = "engine-settings.json"

///|
/// The official OpenSeek proxy endpoint runs use when the provider is
/// `Openseek` — the zero-config default. Must stay under
/// `OpenseekProxyPrefix`, which is what routes the client token to it.
const OpenseekProxyUrl : String = "https://openseek-api.moonbitlang.cn/chat/completions"

///|
/// Which chat-completions endpoint runs talk to. `Openseek` is the
/// zero-config default (the proxy needs no user key); `Deepseek` is the
/// official endpoint with the user's own key; `Custom` is any other
/// DeepSeek-compatible endpoint.
priv enum ApiProvider {
  Openseek
  Deepseek
  Custom
}

///|
fn ApiProvider::wire(self : ApiProvider) -> String {
  match self {
    Openseek => "openseek"
    Deepseek => "deepseek"
    Custom => "custom"
  }
}

///|
/// `None` for an unknown wire name: loading falls back to the default
/// quietly (a corrupted store degrades instead of wedging), while
/// `settings.set` rejects it loudly.
fn ApiProvider::parse(value : String) -> ApiProvider? {
  match value {
    "openseek" => Some(Openseek)
    "deepseek" => Some(Deepseek)
    "custom" => Some(Custom)
    _ => None
  }
}

///|
/// The decoded settings plus `raw`, the file's own object — the save path
/// works on `raw` so fields this build does not know survive a rewrite.
priv struct EngineSettings {
  raw : Map[String, Json]
  version : Int
  provider : ApiProvider
  custom_api_url : String?
  deepseek_api_key : String?
  custom_api_key : String?
  wsl_enabled : Bool
  wsl_distro : String?
  wsl_engine : String?
}

///|
fn settings_file(runtime_dir : @path.Path) -> @path.Path {
  runtime_dir.join(EngineSettingsFileName)
}

///|
/// Read the settings, tolerating absence and corruption as defaults — a
/// broken file only costs the stored values, never the app; it is not
/// overwritten until the next explicit save.
async fn load_engine_settings(runtime_dir : @path.Path?) -> EngineSettings {
  let fields : Map[String, Json] = Map([])
  if runtime_dir is Some(dir) &&
    (@fsx.try_read_text(settings_file(dir)) catch {
      error if @async.is_being_cancelled() => raise error
      _ => None
    })
    is Some(text) &&
    (@json.parse(text) catch { _ => Json::null() }) is Object(parsed) {
    for key, value in parsed {
      fields[key] = value
    }
  }
  decode_settings(fields)
}

///|
fn settings_text(fields : Map[String, Json], key : String) -> String? {
  guard fields.get(key) is Some(String(value)) && !value.trim().is_empty() else {
    return None
  }
  Some(value)
}

///|
fn decode_settings(raw : Map[String, Json]) -> EngineSettings {
  let (wsl_enabled, wsl_distro, wsl_engine) = if raw.get("wsl")
    is Some(Object(wsl)) {
    (
      wsl.get("enabled") is Some(True),
      settings_text(wsl, "distro"),
      settings_text(wsl, "engine"),
    )
  } else {
    (false, None, None)
  }
  {
    raw,
    // Missing reads as 1: version stamping arrived with the first format,
    // so an unstamped file can only be that format (or hand-written).
    version: match raw.get("version") {
      Some(Number(version, ..)) => version.to_int()
      _ => 1
    },
    provider: settings_text(raw, "provider")
    .map(value => ApiProvider::parse(value))
    .flatten()
    .unwrap_or(Openseek),
    custom_api_url: settings_text(raw, "custom_api_url"),
    deepseek_api_key: settings_text(raw, "deepseek_api_key"),
    custom_api_key: settings_text(raw, "custom_api_key"),
    wsl_enabled,
    wsl_distro,
    wsl_engine,
  }
}

///|
/// One `settings.set` request, decoded by the transport layer. Every field
/// is optional: absent = leave unchanged. A present string field is
/// trimmed; empty after trimming clears the stored value. A present `wsl`
/// replaces the whole WSL group.
pub(all) struct SettingsPatch {
  provider : String?
  custom_api_url : String?
  deepseek_api_key : String?
  custom_api_key : String?
  wsl : WslPatch?
}

///|
pub(all) struct WslPatch {
  enabled : Bool
  distro : String?
  engine : String?
}

///|
/// The `settings.get`/`settings.set` reply, and the `settings.changed`
/// broadcast params. Key material never leaves the host — only presence.
fn settings_status_json(settings : EngineSettings) -> Json {
  let status : Map[String, Json] = Map([])
  status["provider"] = Json::string(settings.provider.wire())
  if settings.custom_api_url is Some(url) {
    status["custom_api_url"] = Json::string(url)
  }
  status["has_deepseek_key"] = Json::boolean(
    settings.deepseek_api_key is Some(_),
  )
  status["has_custom_key"] = Json::boolean(settings.custom_api_key is Some(_))
  let wsl : Map[String, Json] = Map([])
  wsl["enabled"] = Json::boolean(settings.wsl_enabled)
  if settings.wsl_distro is Some(distro) {
    wsl["distro"] = Json::string(distro)
  }
  if settings.wsl_engine is Some(engine) {
    wsl["engine"] = Json::string(engine)
  }
  status["wsl"] = Json::object(wsl)
  Json::object(status)
}

///|
/// The `settings.get` reply.
pub async fn settings_status(manager : EngineManager) -> Json {
  settings_status_json(load_engine_settings(manager.runtime_dir))
}

///|
/// Apply one patch and persist it, returning the updated status. The write
/// merges into the file's own object, so fields a newer build added are
/// preserved; a file from a newer version is refused rather than rewritten.
pub async fn update_settings(
  manager : EngineManager,
  patch : SettingsPatch,
) -> Json {
  guard manager.runtime_dir is Some(dir) else {
    raise EngineError("engine settings cannot persist: no runtime directory")
  }
  let current = load_engine_settings(manager.runtime_dir)
  guard current.version <= EngineSettingsVersion else {
    raise EngineError(
      "engine settings were written by a newer OpenSeek; update the app to change them",
    )
  }
  let raw = current.raw
  if patch.provider is Some(value) {
    guard ApiProvider::parse(value.trim().to_owned()) is Some(provider) else {
      raise EngineError("unknown API provider '\{value}'")
    }
    raw["provider"] = Json::string(provider.wire())
  }
  apply_text_patch(raw, "custom_api_url", patch.custom_api_url)
  apply_text_patch(raw, "deepseek_api_key", patch.deepseek_api_key)
  apply_text_patch(raw, "custom_api_key", patch.custom_api_key)
  if patch.wsl is Some(wsl) {
    let group : Map[String, Json] = Map([])
    group["enabled"] = Json::boolean(wsl.enabled)
    apply_text_patch(group, "distro", wsl.distro)
    apply_text_patch(group, "engine", wsl.engine)
    raw["wsl"] = Json::object(group)
  }
  raw["version"] = Json::number(EngineSettingsVersion.to_double())
  write_settings_file(dir, Json::object(raw).stringify(indent=2))
  settings_status_json(decode_settings(raw))
}

///|
/// A present string field is an instruction: trimmed non-empty replaces the
/// stored value, empty clears it. Absent fields never reach here.
fn apply_text_patch(
  fields : Map[String, Json],
  key : String,
  value : String?,
) -> Unit {
  guard value is Some(value) else { return }
  let value = value.trim().to_owned()
  if value.is_empty() {
    fields.remove(key)
  } else {
    fields[key] = Json::string(value)
  }
}

///|
/// Atomic save: write a 0600 temp file, then rename over the target. The
/// file holds a credential, so a crash mid-write must never leave a
/// truncated store — the temp file keeps the full content until the rename
/// lands. Windows may refuse to rename over an existing file; removing the
/// target first narrows atomicity to that one platform's small window.
async fn write_settings_file(runtime_dir : @path.Path, text : String) -> Unit {
  let target = settings_file(runtime_dir)
  let temp = runtime_dir.join(EngineSettingsFileName + ".tmp")
  @fs.write_file(
    temp.to_string(),
    text,
    create_mode=CreateOrTruncate,
    permission=0o600,
  ) catch {
    error if @async.is_being_cancelled() => raise error
    error => raise EngineError("could not write engine settings: \{error}")
  }
  @fs.rename(temp.to_string(), target.to_string()) catch {
    error if @async.is_being_cancelled() => raise error
    _ => {
      @fsx.remove_if_exists(target) catch {
        error if @async.is_being_cancelled() => raise error
        error =>
          raise EngineError("could not replace engine settings: \{error}")
      }
      @fs.rename(temp.to_string(), target.to_string()) catch {
        error if @async.is_being_cancelled() => raise error
        error => raise EngineError("could not save engine settings: \{error}")
      }
    }
  }
}

///|
/// The endpoint a run talks to, resolved from the settings. `api_url` is
/// `None` for the engine's built-in default (the official DeepSeek
/// endpoint). The client no longer sends credentials — this is the one
/// place they enter a run's config.
priv struct ResolvedEndpoint {
  api_key : String
  api_url : String?
}

///|
fn resolved_endpoint(
  settings : EngineSettings,
) -> ResolvedEndpoint raise EngineError {
  match settings.provider {
    Openseek => {
      let url = OpenseekProxyUrl
      let key = configured_api_key(
        None,
        Some(url),
        None,
        client_token?=openseek_client_token(),
      )
      { api_key: key, api_url: Some(url) }
    }
    Deepseek => {
      let key = configured_api_key(
        settings.deepseek_api_key,
        None,
        @env.get("DEEPSEEK"),
        client_token?=openseek_client_token(),
      )
      { api_key: key, api_url: None }
    }
    Custom => {
      guard settings.custom_api_url is Some(url) else {
        raise EngineError("custom endpoint URL is required; set it in Settings")
      }
      let key = configured_api_key(
        settings.custom_api_key,
        Some(url),
        None,
        client_token?=openseek_client_token(),
      )
      { api_key: key, api_url: Some(url) }
    }
  }
}

///|
/// The WSL request the settings imply. On a host without WSL a stored
/// preference (say, a profile copied from a Windows machine) degrades to
/// the native engine instead of failing every run.
fn settings_wsl_request(settings : EngineSettings) -> WslRequest? {
  if settings.wsl_enabled && WslSupported {
    Some({ distro: settings.wsl_distro, engine: settings.wsl_engine })
  } else {
    None
  }
}
