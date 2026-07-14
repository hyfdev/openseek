// The settings store's contract: tolerant reads, merge-preserving atomic
// writes, the version guard, and the run-config resolution built on it.

///|
async fn with_settings_dir(
  body : async (@path.Path, EngineManager) -> Unit,
) -> Unit {
  let dir : @path.Path = Path(@fs.tmpdir(prefix="openseek-settings-"))
  body(dir, new_engine_manager("openseek", runtime_dir=dir)) catch {
    error => {
      @fs.rmdir(dir.to_string(), recursive=true) catch {
        _ => ()
      }
      raise error
    }
  }
  @fs.rmdir(dir.to_string(), recursive=true) catch {
    _ => ()
  }
}

///|
async test "missing settings read as the zero-config defaults" {
  with_settings_dir(async fn(_dir, manager) {
    let settings = load_engine_settings(manager.runtime_dir)
    assert_true(settings.provider is Openseek)
    assert_true(settings.deepseek_api_key is None)
    assert_false(settings.wsl_enabled)
    json_inspect(settings_status(manager), content={
      "provider": "openseek",
      "has_deepseek_key": false,
      "has_custom_key": false,
      "wsl": { "enabled": false },
    })
  })
}

///|
async test "a saved key round-trips as presence, never as text" {
  with_settings_dir(async fn(dir, manager) {
    let status = update_settings(manager, {
      provider: Some("deepseek"),
      custom_api_url: None,
      deepseek_api_key: Some("  sk-secret  "),
      custom_api_key: None,
      wsl: None,
    })
    json_inspect(status, content={
      "provider": "deepseek",
      "has_deepseek_key": true,
      "has_custom_key": false,
      "wsl": { "enabled": false },
    })
    // The status never carries the key; the file carries it trimmed.
    assert_false(status.stringify().contains("sk-secret"))
    let text = @fsx.read_text(settings_file(dir))
    assert_true(text.contains("\"sk-secret\""))
    let reloaded = load_engine_settings(manager.runtime_dir)
    assert_true(reloaded.deepseek_api_key is Some("sk-secret"))
    assert_true(reloaded.provider is Deepseek)
  })
}

///|
async test "a present-but-blank field clears the stored value" {
  with_settings_dir(async fn(_dir, manager) {
    let _ = update_settings(manager, {
      provider: Some("custom"),
      custom_api_url: Some("https://proxy.example/chat/completions"),
      deepseek_api_key: None,
      custom_api_key: Some("sk-custom"),
      wsl: None,
    })
    let status = update_settings(manager, {
      provider: None,
      custom_api_url: Some("   "),
      deepseek_api_key: None,
      custom_api_key: Some(""),
      wsl: None,
    })
    json_inspect(status, content={
      "provider": "custom",
      "has_deepseek_key": false,
      "has_custom_key": false,
      "wsl": { "enabled": false },
    })
  })
}

///|
async test "saves preserve fields a newer build added" {
  with_settings_dir(async fn(dir, manager) {
    @fsx.write_text(
      settings_file(dir),
      "{\"version\": 1, \"future_field\": \"kept\", \"provider\": \"deepseek\"}",
    )
    let _ = update_settings(manager, {
      provider: None,
      custom_api_url: None,
      deepseek_api_key: Some("sk-new"),
      custom_api_key: None,
      wsl: None,
    })
    let text = @fsx.read_text(settings_file(dir))
    assert_true(text.contains("\"future_field\""))
    assert_true(text.contains("\"kept\""))
    // The untouched provider survives the patch too.
    let reloaded = load_engine_settings(manager.runtime_dir)
    assert_true(reloaded.provider is Deepseek)
    assert_true(reloaded.deepseek_api_key is Some("sk-new"))
  })
}

///|
async test "a newer-version file is read best-effort but never rewritten" {
  with_settings_dir(async fn(dir, manager) {
    @fsx.write_text(
      settings_file(dir),
      "{\"version\": 99, \"provider\": \"deepseek\", \"deepseek_api_key\": \"sk-kept\"}",
    )
    // Reads still surface what this build understands.
    let settings = load_engine_settings(manager.runtime_dir)
    assert_true(settings.provider is Deepseek)
    assert_true(settings.deepseek_api_key is Some("sk-kept"))
    // Writes are refused so a downgrade cannot eat the newer schema.
    let refused = try
      update_settings(manager, {
        provider: Some("openseek"),
        custom_api_url: None,
        deepseek_api_key: None,
        custom_api_key: None,
        wsl: None,
      })
    catch {
      EngineError(message) => message
      _ => ""
    } noraise {
      _ => ""
    }
    assert_true(refused.contains("newer"))
    let text = @fsx.read_text(settings_file(dir))
    assert_true(text.contains("\"version\": 99"))
  })
}

///|
async test "an unknown provider is refused on write, defaulted on read" {
  with_settings_dir(async fn(dir, manager) {
    let refused = try
      update_settings(manager, {
        provider: Some("acme"),
        custom_api_url: None,
        deepseek_api_key: None,
        custom_api_key: None,
        wsl: None,
      })
    catch {
      EngineError(message) => message
      _ => ""
    } noraise {
      _ => ""
    }
    assert_true(refused.contains("unknown API provider"))
    // A corrupted store degrades to the zero-config default.
    @fsx.write_text(settings_file(dir), "{\"provider\": \"acme\"}")
    assert_true(load_engine_settings(manager.runtime_dir).provider is Openseek)
  })
}

///|
async test "a corrupt file reads as defaults and survives until a save" {
  with_settings_dir(async fn(dir, manager) {
    @fsx.write_text(settings_file(dir), "{ not json")
    let settings = load_engine_settings(manager.runtime_dir)
    assert_true(settings.provider is Openseek)
    // Nothing rewrote the broken file behind the user's back.
    assert_eq(@fsx.read_text(settings_file(dir)), "{ not json")
  })
}

///|
async test "run config resolves the endpoint from the stored provider" {
  with_settings_dir(async fn(_dir, manager) {
    let _ = update_settings(manager, {
      provider: Some("deepseek"),
      custom_api_url: None,
      deepseek_api_key: Some("sk-stored"),
      custom_api_key: None,
      wsl: None,
    })
    let config = run_config(manager, {
      task: "hello",
      model: None,
      max_steps: None,
      session: None,
      session_root: None,
      workspace: None,
    })
    // The official endpoint is the engine default: no URL override.
    assert_true(config.api_url is None)
    assert_eq(config.api_key, "sk-stored")
    let _ = update_settings(manager, {
      provider: Some("custom"),
      custom_api_url: Some("https://proxy.example/chat/completions"),
      deepseek_api_key: None,
      custom_api_key: None,
      wsl: None,
    })
    let custom = run_config(manager, {
      task: "hello",
      model: None,
      max_steps: None,
      session: None,
      session_root: None,
      workspace: None,
    })
    assert_true(
      custom.api_url is Some("https://proxy.example/chat/completions"),
    )
    // A custom endpoint without a key gets the placeholder, never the
    // stored DeepSeek key.
    assert_eq(custom.api_key, PlaceholderApiKey)
  })
}

///|
async test "a custom provider without a URL refuses to start" {
  with_settings_dir(async fn(_dir, manager) {
    let _ = update_settings(manager, {
      provider: Some("custom"),
      custom_api_url: None,
      deepseek_api_key: None,
      custom_api_key: None,
      wsl: None,
    })
    let refused = try
      run_config(manager, {
        task: "hello",
        model: None,
        max_steps: None,
        session: None,
        session_root: None,
        workspace: None,
      })
    catch {
      EngineError(message) => message
      _ => ""
    } noraise {
      _ => ""
    }
    assert_true(refused.contains("custom endpoint URL is required"))
  })
}
