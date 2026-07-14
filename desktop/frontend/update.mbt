///|
fn should_append_answer(conv : Conversation, answer : String) -> Bool {
  if answer.trim().is_empty() {
    false
  } else if conv.last_assistant_content() is Some(existing) {
    existing != answer
  } else {
    true
  }
}

///|
/// Fold a background snapshot into its conversation without activating it:
/// adopt the transcript + watermark, and re-read once more if commits
/// buffered during the read left a gap. A snapshot for a conversation this
/// client no longer tracks is dropped.
fn apply_session_refresh(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  session : String,
  items : Array[@transcript.TranscriptItem],
  watermark : Int,
) -> (@cmd.Cmd, Model) {
  guard model.find_conversation(session) is Some(conv) else {
    return (@cmd.none, model)
  }
  let (conv, gapped) = conv.adopt_snapshot(items, watermark)
  let commands = [scroll_if_active(model, session)]
  if gapped {
    commands.push(
      refresh_session(
        dispatch,
        session,
        workspace=model.session_workspace(session),
      ),
    )
  }
  (@cmd.batch(commands), model.replace_conversation(conv))
}

///|
/// Scroll the transcript only when `session_id` is the conversation on
/// screen — a background conversation's stream must not yank the visible
/// scroll position around — and only while the user is at the bottom:
/// someone who scrolled up to read history stays where they are.
fn scroll_if_active(model : Model, session_id : String) -> @cmd.Cmd {
  if session_id == model.active_session && model.transcript_pinned {
    scroll_transcript_after_render()
  } else {
    @cmd.none
  }
}

///|
/// Whether an event the engine emits while idle (between turns) — the
/// compaction lifecycle and background-job notices — so the routing must
/// match by last run id: the run that owned the id has already cleared
/// `active_run_id` by the time these arrive.
fn is_idle_event(event : @transcript.EngineEvent) -> Bool {
  match event {
    CompactionStarted
    | CompactionFinished(_)
    | CompactionFailed(_)
    | RuntimeUpdate(_) => true
    _ => false
  }
}

///|
/// Apply an accepted completion row: a slash command runs its action, while a
/// skill mention or symbol reference becomes a chip in the composer's mention
/// tray (its expansion is spliced into the prompt on send). Either way the menu
/// closes and the typed trigger token is cleared from the textarea.
fn accept_completion(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  menu : Completion,
  item : CompletionItem,
) -> (@cmd.Cmd, Model) {
  match menu.kind {
    SlashCommands => run_slash_command(dispatch, model, item.command)
    // The chip carries its envelope form directly: the skill's bare name (its
    // `insert` has a trailing space), or the symbol's name plus resolved
    // location.
    SkillMentions =>
      accept_mention(
        model,
        Skill(name=item.insert.trim().to_owned()),
        range=None,
      )
    Symbols => {
      let (file, line) = if item.path is Some(path) && item.range is Some(range) {
        (path, range.start_line_number)
      } else {
        ("", 0)
      }
      accept_mention(
        model,
        Symbol(name=item.label, file~, line~),
        range=item.range,
      )
    }
  }
}

///|
/// Attach a mention chip to the active conversation's draft (deduplicated),
/// clear the typed trigger token, and close the menu.
fn accept_mention(
  model : Model,
  ref_ : @mention_context.MentionRef,
  range~ : @common.Range?,
) -> (@cmd.Cmd, Model) {
  let conv = model.active()
  let mentions = push_mention(conv.mentions, { ref_, range })
  (
    @cmd.none,
    {
      ..model.replace_conversation({ ..conv, task: "", mentions }),
      completion: None,
    },
  )
}

///|
/// A chip's raw jump path as the workspace-relative form the panel and the
/// host's workspace-rooted ops speak. The steady state is the identity: chips
/// minted since the panel started recording relative names are already
/// relative. A legacy envelope can still carry an absolute path (minted
/// before `cwd` was known); those are brought back inside against the
/// conversation's roots, and `None` — an absolute path outside anything this
/// conversation knows — means there is nothing the panel could open.
fn conversation_relative(
  conv : Conversation,
  path : String,
) -> @pathx.Relative? {
  guard is_absolute_path(path) else { return Some(Relative(path)) }
  let absolute : @pathx.Absolute = Absolute(path)
  for root in [conv.cwd, conv.workspace] {
    if root is Some(root) &&
      absolute.relative_to(root~) is Some(rest) &&
      !rest.is_root() {
      return Some(rest)
    }
  }
  None
}

///|
/// Whether a chip path is lexically absolute (POSIX root or a Windows drive)
/// rather than workspace-relative.
fn is_absolute_path(path : String) -> Bool {
  match path[:] {
    ['/', ..] | ['\\', ..] => true
    [drive, ':', ..] => drive.is_ascii_alphabetic()
    _ => false
  }
}

///|
/// Open (or refocus) the editor side-panel on `path`, revealing `range` when
/// given — the shared tail of a composer chip's and a transcript chip's jump.
/// The raw path comes from a chip or envelope; a legacy absolute one that
/// cannot be brought inside the workspace surfaces as a panel error instead
/// of a bogus host read.
fn open_editor_at(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  path : String,
  range : @common.Range?,
  annotation? : String,
) -> (@cmd.Cmd, Model) {
  let conv = model.active()
  let femit = dispatch.map(msg => FileEditor(msg))
  // Re-root only when the panel's cached tree belongs to another
  // conversation; otherwise `sync_file_panel`'s post-dispatch pass would
  // see a session mismatch and wipe the tab/`open` set below.
  let panel = if model.file_panel.session == conv.session_id {
    model.file_panel
  } else {
    { ..@fileeditor.State::empty(), session: conv.session_id }
  }
  guard conversation_relative(conv, path) is Some(relative) else {
    return (
      @fileeditor.mount_cmds(femit),
      {
        ..model,
        file_panel: {
          ..panel,
          open: true,
          error: "\{path} is outside the conversation workspace",
        },
      },
    )
  }
  let (cmd, panel) = @fileeditor.open_file(
    femit,
    panel,
    file_ctx(model),
    relative,
    range~,
    annotation?,
  )
  (cmd, { ..model, file_panel: panel })
}

///|
/// The command, if any, to fetch workspace symbols for a changed draft. Fires
/// only when the draft is a live `#` query (a non-empty token, no spaces) whose
/// results are not already cached for this conversation — so a fresh keystroke
/// refetches but a repeat of the same query does not.
fn symbol_fetch_cmd(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  value : String,
  session : String,
) -> @cmd.Cmd {
  guard value.has_prefix("#") && trigger_query(value) is Some(query) else {
    return @cmd.none
  }
  if model.symbol_cache.session == session && model.symbol_cache.query == query {
    return @cmd.none
  }
  read_workspace_symbols(
    dispatch,
    session,
    query,
    workspace=workspace_root(model.session_workspace(session)),
  )
}

///|
/// Fold a workspace-symbol reply into the model: cache it and rebuild the menu,
/// but only while it still answers the composer's live `#` query for the active
/// conversation — a reply overtaken by a conversation switch or a later
/// keystroke is dropped, the same staleness guard the file panel uses.
fn apply_symbol_reply(
  model : Model,
  session : String,
  query : String,
  items : Array[CompletionItem],
) -> (@cmd.Cmd, Model) {
  let draft = model.active().task
  guard session == model.active().session_id &&
    draft.has_prefix("#") &&
    trigger_query(draft) is Some(live) &&
    live == query else {
    return (@cmd.none, model)
  }
  let cache : SymbolCache = { session, query, items }
  (
    @cmd.none,
    {
      ..model,
      symbol_cache: cache,
      completion: compute_completion(
        draft,
        model.installed_skills,
        cache,
        session,
      ),
    },
  )
}

///|
/// Run an accepted slash command against the active conversation and close the
/// completion menu. The command text is cleared from the composer; an unknown
/// id just dismisses the menu.
fn run_slash_command(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  command : String,
) -> (@cmd.Cmd, Model) {
  match command {
    "compact" => {
      let conv = model.active()
      // One compaction at a time: a repeat while one is queued or in flight
      // would stack another behind it in the engine's pending queue (the
      // host rejects it anyway) — swallow it like any settled command.
      if !(conv.compaction is NotCompacting) {
        (
          @cmd.none,
          {
            ..model.replace_conversation({ ..conv, task: "" }),
            completion: None,
          },
        )
      } else {
        (
          compact_openseek(
            dispatch,
            session=conv.session_id,
            model=model.selected_model,
            max_steps=model.max_steps,
            workspace?=conv.workspace,
          ),
          {
            ..model.replace_conversation({
              ..conv,
              task: "",
              // Hold the send gate before the host answers: mid-turn the
              // command queues behind the open run, and an idle request may
              // sit in the spawn/write window for seconds (a resumed
              // conversation gets its engine spawned on demand) — a prompt
              // sent into either gap would be consumed and rejected instead
              // of held. compaction_started confirms; CompactRejected clears.
              compaction: if conv.is_running() {
                Queued
              } else {
                Requested
              },
            }),
            completion: None,
          },
        )
      }
    }
    _ => (@cmd.none, { ..model, completion: None })
  }
}

///|
/// Fold one engine event into its conversation. Returns whether the
/// transcript visibly grew (the caller turns that into a scroll command only
/// when this conversation is the one on screen) and the new conversation.
fn apply_engine_event(
  conv : Conversation,
  event : @transcript.EngineEvent,
) -> (Bool, Conversation) {
  match event {
    AgentStep(step) => {
      let conv = conv.clear_streams()
      (
        false,
        // A step can only advance an open, uncancelled turn: after a Stop the
        // stage stays Cancelling (steering a dying turn is refused, so the
        // display must not flip the gate back open), and a stray step for a
        // closed run changes nothing.
        if conv.run is Open(run_id~, stage~) && !(stage is Cancelling) {
          { ..conv, run: Open(run_id~, stage=AtStep(step)) }
        } else {
          conv
        },
      )
    }
    AssistantDelta(content) =>
      if content.is_empty() {
        (false, conv)
      } else {
        (
          true,
          { ..conv, streaming_response: conv.streaming_response + content },
        )
      }
    ReasoningDelta(content) =>
      if content.is_empty() {
        (false, conv)
      } else {
        (
          true,
          { ..conv, streaming_reasoning: conv.streaming_reasoning + content },
        )
      }
    // The turn's full reasoning, emitted once its streaming ends and before
    // the assistant message commits — so the transcript reads thought →
    // answer.
    ReasoningMessage(content) => {
      let next = { ..conv, streaming_reasoning: "" }
      let content = content.trim().to_owned()
      if content.is_empty() {
        (false, next)
      } else {
        (true, next.append_overlay(Reasoning, content))
      }
    }
    AssistantMessage(content) => {
      let conv = conv.clear_streams()
      let content = content.trim().to_owned()
      if content.is_empty() {
        (false, conv)
      } else {
        (true, conv.append_overlay(Assistant(false), content))
      }
    }
    RuntimeUpdate(content) => {
      let update = @transcript.parse_runtime_update(content)
      let next = { ..conv, watcher_status: update.status }
      if !update.status.is_empty() || update.diagnostics.length() > 0 {
        (
          true,
          next.append_overlay(
            Tool(
              name=@transcript.runtime_update_title(update),
              is_error=false,
              brief=None,
            ),
            update.diagnostics.join("\n"),
          ),
        )
      } else {
        (false, next)
      }
    }
    Usage(prompt_tokens~, completion_tokens~) =>
      (false, { ..conv, usage_tokens: prompt_tokens + completion_tokens })
    ToolResult(tool_name~, is_error~, content~, brief~) =>
      (
        true,
        conv.append_overlay(
          Tool(
            name=if tool_name.trim().is_empty() { "tool" } else { tool_name },
            is_error~,
            brief~,
          ),
          content,
        ),
      )
    ToolCallDecodeError(tool_name~, reason~) =>
      (
        true,
        conv.append_overlay(
          Tool(
            name=if tool_name.trim().is_empty() { "tool" } else { tool_name },
            is_error=true,
            brief=None,
          ),
          if reason.trim().is_empty() {
            "tool call decode error"
          } else {
            reason
          },
        ),
      )
    AgentFinished(answer) => {
      let conv = conv.clear_streams()
      let answer = answer.trim().to_owned()
      if should_append_answer(conv, answer) {
        (true, conv.append_overlay(Assistant(false), answer))
      } else {
        (false, conv)
      }
    }
    // The checkpoint notice is not a task answer, but keeping the engine's
    // continuation guidance in the transcript makes the live view agree with
    // durable-session replay. The separate host Finished message closes the
    // run with the non-success `context_yield` outcome.
    ContextYield(answer) => {
      let conv = conv.clear_streams()
      let answer = answer.trim().to_owned()
      if should_append_answer(conv, answer) {
        (true, conv.append_overlay(Assistant(false), answer))
      } else {
        (false, conv)
      }
    }
    AgentAborted(reason) => {
      let content = if reason.trim().is_empty() {
        "aborted"
      } else {
        "aborted: " + reason
      }
      (true, conv.clear_streams().append_overlay(Assistant(true), content))
    }
    MaxStepsExhausted =>
      (
        true,
        conv
        .clear_streams()
        .append_overlay(Assistant(true), "max steps exhausted"),
      )
    AgentSetupFailed(reason) => {
      let content = if reason.trim().is_empty() {
        "setup failed"
      } else {
        "setup failed: " + reason
      }
      (true, conv.clear_streams().append_overlay(Assistant(true), content))
    }
    // The steer took effect at a step boundary: it is part of the
    // conversation now, so echo it as a user message.
    SteerApplied(content) =>
      (true, conv.settle_pending_steer(content).append_overlay(User, content))
    // The steer raced the turn's end through the pipes and was rejected; the
    // text must not vanish silently.
    SteerDropped(content) =>
      (
        true,
        conv
        .settle_pending_steer(content)
        .append_overlay(Assistant(true), steer_dropped_notice(content)),
      )
    // Automatic compaction runs inside this open turn. Show the durable
    // checkpoint with the same Summary card as manual compaction and replay,
    // but leave the between-turn CompactionPhase untouched.
    AutoCompactionFinished(summary) => {
      let summary = summary.trim().to_owned()
      if summary.is_empty() {
        (false, conv)
      } else {
        (true, conv.append_overlay(Summary, summary))
      }
    }
    // Compaction runs while the engine is idle and the next prompt will carry
    // the shrunken context. The summary is appended as a `Summary` item, the
    // same shape a reloaded session shows for the checkpoint, so the live and
    // replayed transcripts agree.
    CompactionStarted => (false, { ..conv, compaction: Compacting })
    CompactionFinished(summary) => {
      let conv = { ..conv, compaction: NotCompacting }
      let summary = summary.trim().to_owned()
      if summary.is_empty() {
        (false, conv)
      } else {
        (true, conv.append_overlay(Summary, summary))
      }
    }
    CompactionFailed(reason) => {
      let content = if reason.trim().is_empty() {
        "compaction failed"
      } else {
        "compaction failed: " + reason
      }
      (
        true,
        { ..conv, compaction: NotCompacting }.append_overlay(
          Assistant(true),
          content,
        ),
      )
    }
  }
}

///|
/// The file-editor package's view of the active conversation: which session
/// the panel serves, the workspace hint its fs ops carry, and the viewer's
/// theme. Recomputed per dispatch — it is only a projection of the model.
fn file_ctx(model : Model) -> @fileeditor.Ctx {
  let conv = model.active()
  {
    session: conv.session_id,
    workspace: conv.workspace,
    dark_mode: model.dark_mode,
    tree_layout: model.tree_layout,
  }
}

///|
/// Reconcile the file panel with the active conversation after every message
/// (see `@fileeditor.sync`). Centralizing it here keeps every
/// conversation-switching handler from having to re-root the panel itself.
fn sync_file_panel(
  dispatch : @cmd.Emit[Msg],
  model : Model,
) -> (Model, @cmd.Cmd) {
  let (panel, cmd) = @fileeditor.sync(
    dispatch.map(msg => FileEditor(msg)),
    model.file_panel,
    file_ctx(model),
  )
  ({ ..model, file_panel: panel }, cmd)
}

///|
fn update(
  dispatch : @cmd.Emit[Msg],
  msg : Msg,
  model : Model,
) -> (@cmd.Cmd, Model) {
  let (cmd, model) = update_msg(dispatch, msg, model)
  let (model, panel_cmd) = sync_file_panel(dispatch, model)
  (@cmd.batch([cmd, panel_cmd]), model)
}

///|
/// Push the model's (already-updated) WSL view to the host as one whole
/// group — the shared tail of the three WSL edit handlers.
fn push_wsl_settings(
  dispatch : @cmd.Emit[Msg],
  model : Model,
) -> (@cmd.Cmd, Model) {
  (
    push_host_settings(
      dispatch,
      wsl_settings_patch(
        enabled=model.wsl_enabled,
        distro=model.wsl_distro,
        engine=model.wsl_engine,
      ),
    ),
    { ..model, settings_saves: model.settings_saves + 1 },
  )
}

///|
fn update_msg(
  dispatch : @cmd.Emit[Msg],
  msg : Msg,
  model : Model,
) -> (@cmd.Cmd, Model) {
  match msg {
    Init =>
      (
        @cmd.batch([
          install_bridge(dispatch),
          load_saved_settings(dispatch),
          watch_transcript_scroll(dispatch),
          watch_color_scheme(dispatch),
          rotate_session(dispatch),
        ]),
        model,
      )
    BridgeReady => {
      // The installed skills also feed the composer's `$` completion, so they
      // are fetched on connect rather than only when the Skills page opens.
      // The startup update check rides here too: settings (the channel)
      // load synchronously at Init, so they are in by bridge time.
      let commands = [
        fetch_sessions(dispatch),
        // In-flight runs, so a page that joined (or reconnected) mid-run
        // learns each live run's identity — the resync half of the
        // protocol's reconnect story (docs/remote-protocol.md).
        fetch_runs(dispatch),
        fetch_host_meta(dispatch),
        fetch_host_settings(dispatch),
        // Legacy client-stored engine settings: the desktop migrates them
        // up to the host, a browser purges them (see `LegacySettingsRead`).
        read_legacy_engine_settings(dispatch),
        fetch_installed_skills(dispatch),
        fetch_archived(dispatch),
        fetch_workspaces(dispatch),
      ]
      // Self-update is the desktop window's alone (see `is_desktop`); a
      // browser never checks, so its update UI never materializes.
      if model.is_desktop {
        commands.push(
          check_for_updates(dispatch, model.update_channel, explicit=false),
        )
      }
      // The resync's other half: whatever landed while this client was away
      // (another client's prompts, items a still-running turn completed, a
      // finished run's verdict) exists only in the store. Reads happen
      // exactly where this client was absent: the conversation on screen
      // re-reads now, every other one re-reads when opened (`OpenSession`
      // always reloads). An in-flight user load keeps right of way.
      let model = match model.find_conversation(model.active_session) {
        Some(conv) if conv.has_begun() && model.loading_session.is_empty() => {
          commands.push(
            refresh_session(
              dispatch,
              conv.session_id,
              workspace=model.session_workspace(conv.session_id),
            ),
          )
          // Buffer commits until the snapshot lands — its watermark decides
          // which of them it already contains.
          model.replace_conversation({ ..conv, sync: Reloading(buffered=[]) })
        }
        _ => model
      }
      (
        @cmd.batch(commands),
        {
          ..model,
          bridge: Connected,
          // The host this bridge just (re)connected to may be a fresh
          // process with no filesystem watcher; forgetting what was watched
          // makes the post-dispatch panel sync re-issue `fs.watch` instead
          // of reading the stale record as "already placed".
          file_panel: { ..model.file_panel, watching: "" },
          // An unusable endpoint routes straight to Settings — the composer
          // could do nothing anyway.
          screen: if model.api_ready() {
            model.screen
          } else {
            Settings
          },
        },
      )
    }
    HostMetaLoaded(wsl~) => (@cmd.none, { ..model, host_wsl: wsl })
    BridgeUnavailable(message) =>
      (@cmd.none, { ..model, bridge: BridgeLost(message) })
    SettingsLoaded(notification_corner~, tree_layout~, update_channel~) =>
      (
        @cmd.none,
        {
          ..model,
          notification_corner: NotificationCorner::parse(notification_corner),
          tree_layout: @fileeditor.TreeLayout::parse(tree_layout),
          update_channel: UpdateChannel::parse(update_channel),
        },
      )
    // The host's settings, from the bridge-time `settings.get` or a peer's
    // edit broadcast. Dropped while this client's own writes are in flight —
    // the payload may predate them; the last write's reply reconciles.
    HostSettingsLoaded(settings) =>
      if model.settings_saves > 0 {
        (@cmd.none, model)
      } else {
        (@cmd.none, model.apply_host_settings(settings))
      }
    HostSettingsApplied(settings) => {
      let next = { ..model, settings_saves: model.settings_saves - 1 }
      // The migration's secrets leave localStorage only once the host
      // confirmed it holds them.
      let cleanup = if next.legacy_cleanup_pending {
        clear_legacy_engine_settings()
      } else {
        @cmd.none
      }
      let next = { ..next, legacy_cleanup_pending: false }
      (
        cleanup,
        if next.settings_saves > 0 {
          next
        } else {
          next.apply_host_settings(settings)
        },
      )
    }
    HostSettingsSaveFailed(message) => {
      let next = {
        ..model,
        settings_saves: model.settings_saves - 1,
        // The push never landed; the legacy values stay in localStorage for
        // the next launch's retry.
        legacy_cleanup_pending: false,
      }
      next.notify_error(dispatch, "Saving settings failed: \{message}")
    }
    LegacySettingsRead(
      provider~,
      custom_url~,
      api_key~,
      custom_api_key~,
      wsl_enabled~,
      wsl_distro~,
      wsl_engine~
    ) =>
      // Only the desktop window migrates: it is the one client whose stored
      // values are unambiguously this host's. A browser page's copy may
      // belong to a different device behind the same origin — pushing it is
      // exactly the leak the host-side store removes — so it is purged.
      if model.is_desktop {
        let patch = legacy_settings_patch(
          provider~,
          custom_url~,
          api_key~,
          custom_api_key~,
          wsl_enabled~,
          wsl_distro~,
          wsl_engine~,
        )
        // Mirror the pushed values optimistically so the Settings page and
        // the ready gate reflect the migration immediately.
        let next = {
          ..model,
          api_provider: ApiProvider::parse(provider),
          custom_api_url: custom_url.trim().to_owned(),
          deepseek_key_saved: model.deepseek_key_saved ||
          !api_key.trim().is_empty(),
          custom_key_saved: model.custom_key_saved ||
          !custom_api_key.trim().is_empty(),
          wsl_enabled: wsl_enabled == "1",
          wsl_distro: wsl_distro.trim().to_owned(),
          wsl_engine: wsl_engine.trim().to_owned(),
          settings_saves: model.settings_saves + 1,
          legacy_cleanup_pending: true,
        }
        (push_host_settings(dispatch, patch), next)
      } else {
        (clear_legacy_engine_settings(), model)
      }
    TaskChanged(value) => {
      let session = model.active().session_id
      (
        symbol_fetch_cmd(dispatch, model, value, session),
        {
          ..model.replace_conversation({ ..model.active(), task: value }),
          completion: compute_completion(
            value,
            model.installed_skills,
            model.symbol_cache,
            session,
          ),
        },
      )
    }
    CompletionMove(delta) =>
      if model.completion is Some(menu) {
        (@cmd.none, { ..model, completion: Some(menu.shifted(delta)) })
      } else {
        (@cmd.none, model)
      }
    CompletionDismiss => (@cmd.none, { ..model, completion: None })
    RemoveMention(index) => {
      let conv = model.active()
      guard conv.mentions.get(index) is Some(_) else {
        return (@cmd.none, model)
      }
      let mentions = conv.mentions.copy()
      let _ = mentions.remove(index)
      (@cmd.none, model.replace_conversation({ ..conv, mentions, }))
    }
    JumpToMention(index) => {
      let conv = model.active()
      guard conv.mentions.get(index) is Some(mention) else {
        return (@cmd.none, model)
      }
      guard mention_target(mention.ref_) is Some(target) else {
        return (@cmd.none, model)
      }
      // A draft chip still holds the full resolved range (columns included);
      // the envelope-shaped target range is the fallback.
      let range = if mention.range is Some(_) {
        mention.range
      } else {
        target.range
      }
      open_editor_at(
        dispatch,
        model,
        target.file,
        range,
        annotation?=target.annotation,
      )
    }
    JumpToLocation(path~, range~, annotation~) =>
      open_editor_at(dispatch, model, path, range, annotation?)
    // Intercepted here rather than delegated to the fileeditor package: the
    // comment becomes an annotation chip on the composer draft, which only
    // this model knows about. `quote`/`range` come from the panel's viewer.
    FileEditor(
      EditorCommentAdded(
        resource~,
        file~,
        range~,
        quote~,
        comment~,
        feedback_id~
      )
    ) => {
      let conv = model.active()
      let mentions = push_mention(conv.mentions, {
        ref_: Annotation(
          file=file.0,
          start_line=range.start_line_number,
          end_line=range.end_line_number,
          quote~,
          comment~,
        ),
        range: Some(range),
      })
      // The chip is the comment's carrier from here on; clearing the editor's
      // own bubble keeps the two from drifting apart (and from double-sending
      // if the user comments again).
      (
        @fileeditor.remove_editor_feedback(resource, feedback_id),
        model.replace_conversation({ ..conv, mentions, }),
      )
    }
    CompletionAccept =>
      if model.completion is Some(menu) && menu.current() is Some(item) {
        accept_completion(dispatch, model, menu, item)
      } else {
        (@cmd.none, { ..model, completion: None })
      }
    CompletionPick(index) =>
      if model.completion is Some(menu) && menu.items.get(index) is Some(item) {
        accept_completion(dispatch, model, menu, item)
      } else {
        (@cmd.none, { ..model, completion: None })
      }
    SymbolsLoaded(session~, query~, items~) =>
      apply_symbol_reply(model, session, query, items)
    // A failed search reads as "no symbols": cache an empty result for the
    // query so the menu settles on "No symbols" rather than spinning.
    SymbolsFailed(session~, query~) =>
      apply_symbol_reply(model, session, query, [])
    ModelChanged(value) => (@cmd.none, { ..model, selected_model: value })
    MaxStepsChanged(value) => (@cmd.none, { ..model, max_steps: value })
    SetupApiKeyChanged(value) => (@cmd.none, { ..model, setup_api_key: value })
    ProviderChanged(value) => {
      let provider = ApiProvider::parse(value)
      (
        push_host_settings(dispatch, provider_settings_patch(provider)),
        {
          ..model,
          api_provider: provider,
          setup_api_key: "",
          settings_saves: model.settings_saves + 1,
        },
      )
    }
    CustomApiUrlChanged(value) =>
      (
        push_host_settings(dispatch, custom_url_settings_patch(value)),
        {
          ..model,
          custom_api_url: value,
          settings_saves: model.settings_saves + 1,
        },
      )
    WslModeChanged(value) =>
      push_wsl_settings(dispatch, { ..model, wsl_enabled: value == "wsl" })
    WslDistroChanged(value) =>
      push_wsl_settings(dispatch, { ..model, wsl_distro: value })
    WslEngineChanged(value) =>
      push_wsl_settings(dispatch, { ..model, wsl_engine: value })
    NotificationCornerChanged(value) => {
      let corner = NotificationCorner::parse(value)
      (
        save_notification_corner(corner),
        { ..model, notification_corner: corner },
      )
    }
    TreeLayoutChanged(value) => {
      let layout = @fileeditor.TreeLayout::parse(value)
      // The dock flips purely in CSS, but the viewer cannot see its host
      // change size on its own — remeasure it (mount_cmds is idempotent and
      // carries the remeasure).
      (
        @cmd.batch([
          save_tree_layout(layout),
          @fileeditor.mount_cmds(dispatch.map(msg => FileEditor(msg))),
        ]),
        { ..model, tree_layout: layout },
      )
    }
    NotificationExpired(id) | DismissNotification(id) =>
      (
        @cmd.none,
        { ..model, notifications: model.notifications.filter(t => t.id != id) },
      )
    UpdateChannelChanged(value) => {
      let channel = UpdateChannel::parse(value)
      // Whatever the old channel said no longer applies; the next check
      // (Settings button or next launch) answers for the new one.
      (
        save_update_channel(channel),
        { ..model, update_channel: channel, update_ux: UpdateUnknown },
      )
    }
    CheckForUpdates =>
      // A user-initiated check; never stacks on an in-flight one, and never
      // interrupts a download already underway.
      if model.update_ux
        is (CheckingForUpdate
        | ConfirmingRestart(..)
        | DownloadingUpdate(..)
        | RestartingForUpdate(..)) {
        (@cmd.none, model)
      } else {
        (
          check_for_updates(dispatch, model.update_channel, explicit=true),
          { ..model, update_ux: CheckingForUpdate },
        )
      }
    UpdateCheckFinished(result~, explicit~) => {
      // A stale reply must not clobber a flow the user has since started
      // (confirming, downloading); only the waiting states accept results.
      guard model.update_ux
        is (UpdateUnknown
        | CheckingForUpdate
        | UpToDate
        | UpdateCheckFailed(..)) else {
        return (@cmd.none, model)
      }
      match result {
        CheckFound(version~, installable~) =>
          (
            @cmd.none,
            { ..model, update_ux: UpdateAvailable(version~, installable~) },
          )
        CheckUpToDate =>
          (
            @cmd.none,
            {
              ..model
              // Only worth stating when the user asked; a quiet startup
              // check leaves nothing behind.
              ,
              update_ux: if explicit {
                UpToDate
              } else {
                UpdateUnknown
              },
            },
          )
        CheckUnreachable(reason~) =>
          // Offline is routine for the app, an answer for the user.
          if explicit {
            (
              @cmd.none,
              {
                ..model,
                update_ux: UpdateCheckFailed(
                  message="Could not reach the update server: \{reason}",
                ),
              },
            )
          } else {
            (@cmd.none, { ..model, update_ux: UpdateUnknown })
          }
        CheckMalformed(reason~) =>
          // A garbage manifest also happens under captive portals, so the
          // app asking stays quiet (the host logged it); the user asking
          // gets the truth.
          if explicit {
            (
              @cmd.none,
              {
                ..model,
                update_ux: UpdateCheckFailed(
                  message="The update server answered unusably: \{reason}",
                ),
              },
            )
          } else {
            (@cmd.none, { ..model, update_ux: UpdateUnknown })
          }
        CheckBroken(version~, reason~) => {
          // A broken package entry can only be the publisher's fault:
          // loud both ways.
          let message = "OpenSeek \{version} is published but its package is unusable: \{reason}"
          let (cmd, next) = if explicit {
            (@cmd.none, model)
          } else {
            model.notify_error(dispatch, message)
          }
          (cmd, { ..next, update_ux: UpdateCheckFailed(message~) })
        }
      }
    }
    UpdateClicked =>
      // Only meaningful while an installable release is on offer; the
      // button does not render otherwise, but a stale click must not
      // restart a download.
      if model.update_ux is UpdateAvailable(version~, installable=true) {
        if model.any_conversation_busy() {
          (@cmd.none, { ..model, update_ux: ConfirmingRestart(version~) })
        } else {
          (
            download_update(dispatch, model.update_channel),
            { ..model, update_ux: DownloadingUpdate(version~) },
          )
        }
      } else {
        (@cmd.none, model)
      }
    ConfirmUpdateRestart =>
      if model.update_ux is ConfirmingRestart(version~) {
        (
          download_update(dispatch, model.update_channel),
          { ..model, update_ux: DownloadingUpdate(version~) },
        )
      } else {
        (@cmd.none, model)
      }
    CancelUpdateRestart =>
      if model.update_ux is ConfirmingRestart(version~) {
        (
          @cmd.none,
          { ..model, update_ux: UpdateAvailable(version~, installable=true) },
        )
      } else {
        (@cmd.none, model)
      }
    UpdateDownloaded =>
      if model.update_ux is DownloadingUpdate(version~) {
        (
          apply_update(dispatch),
          { ..model, update_ux: RestartingForUpdate(version~) },
        )
      } else {
        (@cmd.none, model)
      }
    UpdateFailed(message~) => {
      // Download or swap failed: say why, and put the button back so the
      // user can retry.
      let (cmd, next) = model.notify_error(dispatch, message)
      let update_ux = match next.update_ux {
        DownloadingUpdate(version~) | RestartingForUpdate(version~) =>
          UpdateAvailable(version~, installable=true)
        other => other
      }
      (cmd, { ..next, update_ux, })
    }
    UpdateApplied => (close_window(), model)
    OpenSetup => (@cmd.none, { ..model, screen: Settings, setup_api_key: "" })
    ToggleSidebar => (@cmd.none, { ..model, sidebar_open: !model.sidebar_open })
    ToggleChatsSection =>
      (@cmd.none, { ..model, chats_collapsed: !model.chats_collapsed })
    ToggleWorkspacesSection =>
      (
        @cmd.none,
        { ..model, workspaces_collapsed: !model.workspaces_collapsed },
      )
    SaveApiKey => {
      let api_key = model.setup_api_key.trim().to_owned()
      if api_key.is_empty() {
        (@cmd.none, model)
      } else {
        match model.api_provider {
          // The key goes straight to the host's store; the mirror keeps
          // only its presence. Saving the key that completes the setup
          // returns to the chat — the same auto-dismiss the popup used to
          // have — optimistically; a failed save comes back as a toast.
          Deepseek | Custom as provider => {
            let next = {
              ..model,
              deepseek_key_saved: model.deepseek_key_saved ||
              provider is Deepseek,
              custom_key_saved: model.custom_key_saved || provider is Custom,
              setup_api_key: "",
              settings_saves: model.settings_saves + 1,
            }
            (
              push_host_settings(
                dispatch,
                api_key_settings_patch(provider, api_key),
              ),
              { ..next, screen: if next.api_ready() { Chat } else { Settings } },
            )
          }
          Openseek => (@cmd.none, { ..model, setup_api_key: "" })
        }
      }
    }
    OpenSkills => {
      // The catalog is fetched once per app run (and again after a
      // failure); the installed list is cheap and refreshes on every open.
      let (catalog_cmd, skills_catalog) = match model.skills_catalog {
        CatalogIdle | CatalogFailed(_) =>
          (fetch_skills_catalog(dispatch), CatalogLoading)
        current => (@cmd.none, current)
      }
      (
        @cmd.batch([catalog_cmd, fetch_installed_skills(dispatch)]),
        { ..model, screen: Skills, skills_catalog, skills_notice: "" },
      )
    }
    SkillsQueryChanged(value) => (@cmd.none, { ..model, skills_query: value })
    SkillsCatalogLoaded(items) =>
      (@cmd.none, { ..model, skills_catalog: CatalogReady(items) })
    SkillsCatalogFailed(message) =>
      (@cmd.none, { ..model, skills_catalog: CatalogFailed(message) })
    InstalledSkillsLoaded(items) =>
      (@cmd.none, { ..model, installed_skills: items })
    SkillsNotice(message) => (@cmd.none, { ..model, skills_notice: message })
    InstallSkill(item) => {
      let key = @transcript.market_source_label(item)
      if model.skills_busy.contains(key) {
        (@cmd.none, model)
      } else {
        let skills_busy = model.skills_busy.copy()
        skills_busy.push(key)
        (
          install_skill(dispatch, item),
          { ..model, skills_busy, skills_notice: "" },
        )
      }
    }
    UninstallSkill(id) =>
      if model.skills_busy.contains(id) {
        (@cmd.none, model)
      } else {
        let skills_busy = model.skills_busy.copy()
        skills_busy.push(id)
        (
          uninstall_skill(dispatch, id),
          { ..model, skills_busy, skills_notice: "" },
        )
      }
    SkillActionDone(key~, error~) => {
      let skills_busy = model.skills_busy.filter(entry => entry != key)
      if error.is_empty() {
        // The library changed; what the panel shows must come from disk,
        // not from a client-side guess.
        (fetch_installed_skills(dispatch), { ..model, skills_busy, })
      } else {
        (@cmd.none, { ..model, skills_busy, skills_notice: error })
      }
    }
    Send => {
      let conv = model.active()
      // The outgoing prompt is the typed text with the chips folded in as the
      // `<user_mentions>` envelope. Typed text is required — chips alone are
      // context without an instruction and stay in the composer.
      let task = compose_prompt(conv.mentions, conv.task).trim().to_owned()
      if !conv.draft_sendable() ||
        !(model.bridge is Connected) ||
        !model.api_ready() {
        (@cmd.none, model)
      } else if conv.is_running() {
        // Submitting while this conversation's turn runs steers it: the text
        // is folded into the running turn at its next step boundary and
        // echoed back as a `steer_applied` event. A turn being cancelled
        // cannot be steered — the steer could outlive the dying turn in the
        // engine's queue and contaminate a later prompt — so the text stays
        // in the composer.
        if conv.run is Open(run_id~, stage~) && !(stage is Cancelling) {
          let pending_steers = conv.pending_steers.copy()
          pending_steers.push(task)
          (
            @cmd.batch([
              steer_openseek(dispatch, conv.session_id, task, run_id),
              scroll_transcript_after_render(),
            ]),
            {
              ..model.replace_conversation({
                ..conv,
                pending_steers,
                task: "",
                mentions: [],
              }),
              transcript_pinned: true,
              completion: None,
            },
          )
        } else {
          (@cmd.none, model)
        }
      } else if !(conv.compaction is NotCompacting) {
        // A prompt submitted mid-compaction would sit in the serve engine's
        // queue behind it, where Stop (which cancels only the compaction)
        // cannot reach it — the user's cancel would not stop the submitted
        // work. A queued or just-requested compaction is the same gap one
        // step earlier: the command is on its way and compaction_started has
        // not yet arrived. The draft stays in the composer until the
        // compaction settles.
        (@cmd.none, model)
      } else {
        let next = conv.append_overlay(User, task)
        let next = {
          ..next,
          task: "",
          mentions: [],
          run: Starting,
          usage_tokens: 0,
        }
        (
          @cmd.batch([
            start_openseek(
              dispatch,
              task,
              model.selected_model,
              model.max_steps,
              conv.session_id,
              workspace=conv.workspace,
            ),
            scroll_transcript_after_render(),
          ]),
          // Submitting is an explicit jump to the conversation's tail, so it
          // re-pins a transcript the user had scrolled away from.
          {
            ..model.replace_conversation(next),
            transcript_pinned: true,
            completion: None,
          },
        )
      }
    }
    SteerUndelivered(session~, text~) =>
      // The steer never reached the engine, so no `steer_applied` /
      // `steer_dropped` event will settle it — report the loss here instead.
      if model.find_conversation(session) is Some(conv) {
        let settled = conv.settle_pending_steer(text)
        if settled.pending_steers.length() == conv.pending_steers.length() {
          (@cmd.none, model)
        } else {
          (
            scroll_if_active(model, session),
            model.replace_conversation(
              settled.append_overlay(
                Assistant(true),
                steer_dropped_notice(text),
              ),
            ),
          )
        }
      } else {
        (@cmd.none, model)
      }
    Stop => {
      let conv = model.active()
      if conv.run is Open(run_id~, ..) {
        (
          cancel_openseek(dispatch, run_id),
          model.replace_conversation({
            ..conv,
            run: Open(run_id~, stage=Cancelling),
          }),
        )
      } else {
        (@cmd.none, model)
      }
    }
    NewChat =>
      // A fresh conversation can start at any time: the current one keeps
      // running in the background and stays one sidebar click away. It lands
      // in the active workspace — the one the on-screen conversation uses.
      (rotate_session(dispatch), { ..model, loading_session: "" })
    NewChatIn(workspace) =>
      // A workspace section's own "new chat": the fresh conversation lands in
      // that project, and the workspace stays active for the next one. A new
      // loose chat unfolds the Chats section so its row is visible; a new
      // workspace chat unfolds the Workspaces section for the same reason.
      (
        rotate_session(dispatch),
        {
          ..model,
          active_workspace: workspace,
          loading_session: "",
          chats_collapsed: model.chats_collapsed && !workspace.is_empty(),
          workspaces_collapsed: model.workspaces_collapsed &&
          workspace.is_empty(),
        },
      )
    SessionRotated(session_id) => {
      let activated = model.activate(session_id)
      // A rotation creates the conversation, so stamp it with the workspace
      // it was asked into; an existing conversation keeps its own.
      let conversations = activated.conversations.map(conv => {
        if conv.session_id == session_id &&
          conv.messages.length() == 0 &&
          !conv.is_running() {
          { ..conv, workspace: workspace_root(model.active_workspace) }
        } else {
          conv
        }
      })
      (
        @cmd.none,
        {
          ..activated,
          conversations,
          screen: Chat,
          transcript_pinned: true,
          loading_session: "",
          completion: None,
        },
      )
    }
    SessionsLoaded(items) => (@cmd.none, { ..model, sessions: items })
    WorkspacesLoaded(paths) => {
      // A workspace that vanished from the registry cannot host runs anymore;
      // conversations attached to it fall back to the default store so their
      // next start does not error on an unregistered path.
      let conversations = model.conversations.map(conv => {
        if conv.workspace is Some(workspace) && !paths.contains(workspace.0) {
          { ..conv, workspace: None }
        } else {
          conv
        }
      })
      let active_workspace = if model.active_workspace.is_empty() ||
        paths.contains(model.active_workspace) {
        model.active_workspace
      } else {
        ""
      }
      (
        @cmd.none,
        { ..model, workspaces: paths, conversations, active_workspace },
      )
    }
    PickWorkspace => {
      let picker = opening_workspace_picker()
      (
        browse_directory(dispatch, "", generation=picker.generation),
        { ..model, workspace_picker: Some(picker) },
      )
    }
    WorkspacePickerNavigate(path) =>
      match model.workspace_picker {
        Some(picker) => {
          let generation = picker.generation + 1
          (
            browse_directory(dispatch, path, generation~),
            {
              ..model,
              workspace_picker: Some({ ..picker, loading: true, generation }),
            },
          )
        }
        None => (@cmd.none, model)
      }
    WorkspacePickerLoaded(path~, entries~, generation~) =>
      // A listing for a picker the user already closed — or one answering
      // a navigation that has since been superseded — is dropped. The
      // go-to field clears on arrival: the breadcrumb shows the location,
      // and the field is for typing the next jump.
      match model.workspace_picker {
        Some(picker) if picker.generation == generation =>
          (
            @cmd.none,
            {
              ..model,
              workspace_picker: Some({
                path,
                entries,
                input: "",
                loading: false,
                error: None,
                generation,
              }),
            },
          )
        _ => (@cmd.none, model)
      }
    WorkspacePickerFailed(message~, generation~) =>
      match model.workspace_picker {
        Some(picker) if picker.generation == generation =>
          (
            @cmd.none,
            {
              ..model,
              workspace_picker: Some({
                ..picker,
                loading: false,
                error: Some(message),
              }),
            },
          )
        _ => (@cmd.none, model)
      }
    WorkspacePickerInput(text) =>
      match model.workspace_picker {
        Some(picker) =>
          (
            @cmd.none,
            { ..model, workspace_picker: Some({ ..picker, input: text }) },
          )
        None => (@cmd.none, model)
      }
    WorkspacePickerConfirm =>
      match model.workspace_picker {
        // Confirm registers the directory the host last listed — always
        // something it confirmed exists — never raw field text; Enter in
        // the field navigates (and validates) first.
        Some(picker) if !picker.path.is_empty() =>
          (
            add_workspace(dispatch, picker.path),
            { ..model, workspace_picker: None },
          )
        _ => (@cmd.none, model)
      }
    WorkspacePickerClose => (@cmd.none, { ..model, workspace_picker: None })
    RemoveWorkspace(path) => (remove_workspace(dispatch, path), model)
    WorkspaceFailed(message) =>
      model.notify_error(dispatch, "Workspace error: \{message}")
    ArchiveSession(session_id) => (archive_session(dispatch, session_id), model)
    UnarchiveSession(session_id) =>
      (unarchive_session(dispatch, session_id), model)
    ArchivedLoaded(items) => {
      // Live client state for anything archived is dropped; when that
      // includes the conversation on screen, rotate to a fresh chat.
      let archived_now = (id : String) => {
        items.iter().any(item => item.id == id)
      }
      let conversations = model.conversations.filter(conv => {
        !archived_now(conv.session_id)
      })
      let next = { ..model, archived: items, conversations }
      if archived_now(model.active_session) {
        (rotate_session(dispatch), { ..next, loading_session: "" })
      } else {
        (@cmd.none, next)
      }
    }
    ArchiveFailed(message) =>
      model.notify_error(dispatch, "Archive failed: \{message}")
    SessionsFailed(message) =>
      model.notify_error(dispatch, "Session list unavailable: \{message}")
    // Another client archived or unarchived a conversation; both sidebar
    // lists are stale, and `ArchivedLoaded` drops any live state this client
    // still holds for a now-archived conversation.
    SessionsChanged =>
      (@cmd.batch([fetch_sessions(dispatch), fetch_archived(dispatch)]), model)
    NotificationClicked(run_id~) => {
      // The run has finished by the time its notification is clicked, so the
      // owner usually matches by last run id; a still-running owner (steered
      // runs re-notify per turn) matches by active run.
      let conv = if model.conversation_by_last_run(run_id) is Some(conv) {
        Some(conv)
      } else {
        model.conversation_by_run(run_id)
      }
      if conv is Some(conv) {
        update_msg(dispatch, OpenSession(conv.session_id), model)
      } else {
        (@cmd.none, model)
      }
    }
    OpenSession(session_id) =>
      // Selecting a conversation always returns to the chat — including
      // re-selecting the active one from the Skills page.
      if session_id.is_empty() {
        (@cmd.none, model)
      } else if session_id == model.active_session {
        (
          @cmd.none,
          { ..model, screen: Chat, loading_session: "", completion: None },
        )
      } else if model.find_conversation(session_id) is Some(conv) {
        // Switching focus; the transcript re-pins at the tail. The store is
        // also re-read behind the switch — the local copy may date from
        // before a reconnect, or another client may be driving this
        // conversation — and the current view stays on screen while the
        // reply is in flight. A conversation that never began has nothing
        // stored to read.
        let reread = conv.has_begun()
        // Buffer commits while the re-read is in flight; the snapshot's
        // watermark reconciles them when it lands.
        let model = if reread {
          model.replace_conversation({ ..conv, sync: Reloading(buffered=[]) })
        } else {
          model
        }
        (
          if reread {
            @cmd.batch([
              scroll_transcript_after_render(),
              open_session(
                dispatch,
                session_id,
                workspace=model.session_workspace(session_id),
              ),
            ])
          } else {
            scroll_transcript_after_render()
          },
          {
            ..model.activate(session_id),
            screen: Chat,
            transcript_pinned: true,
            loading_session: if reread {
              session_id
            } else {
              ""
            },
            completion: None,
            active_workspace: workspace_token(conv.workspace),
          },
        )
      } else {
        // The sidebar item says which store holds the session; opening it
        // also makes its workspace the active one, so "New chat" follows.
        let workspace = model.session_workspace(session_id)
        (
          open_session(dispatch, session_id, workspace~),
          {
            ..model,
            screen: Chat,
            loading_session: session_id,
            active_workspace: workspace,
          },
        )
      }
    SessionLoaded(session=session_id, items~, watermark~) =>
      if model.loading_session != session_id {
        // Overtaken by a newer selection — but fresh durable data is never
        // wasted: fold it in as a background refresh (no activation).
        apply_session_refresh(dispatch, model, session_id, items, watermark)
      } else {
        // The store's transcript replaces the local copy wholesale — the
        // store is the single source of truth for committed items, and
        // nothing else ever joins `messages`, so duplicates are impossible
        // by construction. Live client-side state (run phase, streaming
        // buffers, pending steers, the composer draft) rides across
        // untouched; the overlay resets — anything the snapshot does not
        // contain comes back through its own `session.event` commit.
        let (conv, gapped) = (match model.find_conversation(session_id) {
          Some(conv) => conv
          None =>
            empty_conversation(
              session_id,
              workspace=model.session_workspace(session_id),
            )
        }).adopt_snapshot(items, watermark)
        // The host derives the resumed workspace from the session id, so
        // the branch probe sends no cwd.
        let commands = [
          scroll_transcript_after_render(),
          fetch_branch(dispatch, session_id, None),
        ]
        if gapped {
          commands.push(
            refresh_session(
              dispatch,
              session_id,
              workspace=model.session_workspace(session_id),
            ),
          )
        }
        (
          @cmd.batch(commands),
          {
            ..model.replace_conversation(conv).activate(session_id),
            transcript_pinned: true,
            loading_session: "",
            completion: None,
          },
        )
      }
    SessionRefreshed(session~, items~, watermark~) =>
      apply_session_refresh(dispatch, model, session, items, watermark)
    SessionRefreshFailed(session~) =>
      // Drop back to Synced (discarding the buffer): the next commit's gap
      // check re-issues the read, so a transient failure heals itself.
      if model.find_conversation(session) is Some(conv) {
        (@cmd.none, model.replace_conversation({ ..conv, sync: Synced }))
      } else {
        (@cmd.none, model)
      }
    SessionCommitted(session~, sequence~, kind~, payload~) =>
      if model.find_conversation(session) is Some(conv) {
        match conv.sync {
          // A read is in flight: buffer — its snapshot's watermark decides
          // whether this commit is already contained once it lands.
          Reloading(buffered~) => {
            let buffered = buffered.copy()
            buffered.push({ sequence, kind, payload })
            (
              @cmd.none,
              model.replace_conversation({ ..conv, sync: Reloading(buffered~) }),
            )
          }
          Synced =>
            if sequence <= conv.watermark {
              // Old news: the snapshot (or an earlier commit) already
              // carried it. Re-broadcasts are safe by construction.
              (@cmd.none, model)
            } else if sequence == conv.watermark + 1 {
              let (grew, next) = conv.apply_commit(kind, payload)
              (
                if grew {
                  scroll_if_active(model, session)
                } else {
                  @cmd.none
                },
                model.replace_conversation({ ..next, watermark: sequence }),
              )
            } else {
              // A gap: this client missed a broadcast (kicked as a slow
              // subscriber, a host restart, an external writer). The record
              // is the source of truth — re-read it, buffering from here.
              (
                refresh_session(
                  dispatch,
                  session,
                  workspace=model.session_workspace(session),
                ),
                model.replace_conversation({
                  ..conv,
                  sync: Reloading(buffered=[{ sequence, kind, payload }]),
                }),
              )
            }
        }
      } else {
        // A conversation this client never opened: nothing local to extend.
        // Its transcript is read fresh when opened.
        (@cmd.none, model)
      }
    TranscriptPinned(pinned) =>
      (@cmd.none, { ..model, transcript_pinned: pinned })
    // Pin eagerly so the button hides on the click's own render; the scroll
    // watcher would only confirm it after the scroll settles.
    JumpToLatest =>
      (scroll_transcript_after_render(), { ..model, transcript_pinned: true })
    ColorSchemeChanged(dark) => (@cmd.none, { ..model, dark_mode: dark })
    BranchLoaded(session~, branch~) =>
      if model.find_conversation(session) is Some(conv) {
        (@cmd.none, model.replace_conversation({ ..conv, branch, }))
      } else {
        (@cmd.none, model)
      }
    OpenFile(path) => {
      // A relative path is taken against the active conversation's working
      // directory: its `cwd` for a live run, or — when resumed without one —
      // the directory the host derives from the session id. Absolute paths
      // open directly. No workspace containment — the agent surfaced it.
      let conv = model.active()
      (open_file(dispatch, conv.session_id, cwd=conv.cwd, path), model)
    }
    ToggleLauncher => {
      let opening = !model.launcher.open
      // Probe the host the first time the menu opens (and again after a
      // failure); the result is kept for the app run.
      let cmd = if opening && !(model.launcher.apps is AppsFetched(_)) {
        fetch_apps(dispatch)
      } else {
        @cmd.none
      }
      (cmd, { ..model, launcher: { ..model.launcher, open: opening } })
    }
    LauncherLoaded(apps) =>
      (
        @cmd.none,
        { ..model, launcher: { ..model.launcher, apps: AppsFetched(apps) } },
      )
    LauncherFailed(message) =>
      (
        @cmd.none,
        { ..model, launcher: { ..model.launcher, apps: AppsFailed(message) } },
      )
    LaunchApp(app) => {
      let conv = model.active()
      (
        launch_app(dispatch, conv.session_id, cwd=conv.cwd, app),
        { ..model, launcher: { ..model.launcher, open: false } },
      )
    }
    Started(run_id~, session~, model=selected_model, max_steps~, cwd~, task~) => {
      // A run another client started may reach us with no local conversation
      // for its session (an `agent.runs` resync on a fresh page, or a live
      // start for a session this client never opened): materialize one, so
      // the run is trackable — streamable, cancellable, steerable — from
      // every client, not just the one that sent the prompt. A run this
      // client sent is already `Starting` when its `started` arrives (the
      // send handler flips the phase before the request leaves); anything
      // else is another client's run.
      let (conv, foreign) = match model.find_conversation(session) {
        Some(conv) => (conv, !conv.is_running())
        None =>
          (
            empty_conversation(
              session,
              workspace=model.session_workspace(session),
            ),
            true,
          )
      }
      // The prompt bubble itself is not appended here — not even from the
      // pushed `task`: the durable transcript's only sources are snapshots
      // and `session.event` commits, and the prompt's own commit (or the
      // refresh below) brings it. `task` still rides on the event for
      // clients that render run identity elsewhere.
      ignore(task)
      // A foreign run means the store holds items this client never saw —
      // the prompt at least. The conversation on screen re-reads it now (a
      // background one catches up through commits, or when opened); commits
      // buffer until the snapshot lands. An in-flight user load keeps right
      // of way.
      let refresh = foreign &&
        session == model.active_session &&
        model.loading_session.is_empty()
      let updated = model.replace_conversation({
        ..conv,
        run: Open(run_id~, stage=Opened),
        last_run_id: Some(run_id),
        sync: if refresh {
          Reloading(buffered=[])
        } else {
          conv.sync
        },
        // A started run always reports its directory, but a malformed
        // event decodes as `None`; keeping the previous root beats
        // forgetting one we already knew.
        cwd: if cwd is Some(_) {
          cwd
        } else {
          conv.cwd
        },
      })
      // The run's workspace directory now exists, so the branch chip can be
      // probed (and refreshed — a rerun may follow a checkout).
      let commands = [fetch_branch(dispatch, session, cwd)]
      if refresh {
        commands.push(
          refresh_session(
            dispatch,
            session,
            workspace=updated.session_workspace(session),
          ),
        )
      }
      // Sync the global model/step settings only when this start belongs to
      // the conversation on screen. A slow background start (the user switched
      // chats mid-spawn) must not overwrite settings the user has since
      // changed for the now-active conversation.
      if session == updated.active_session {
        (
          @cmd.batch(commands),
          { ..updated, selected_model, max_steps: max_steps.to_string() },
        )
      } else {
        (@cmd.batch(commands), updated)
      }
    }
    RunsSettled(live~) => {
      // A conversation still showing an open run the host no longer has: the
      // run ended while this client was away, and its terminal event will
      // never be replayed, so the phase settles here. How it ended is
      // unknowable (`ended=None`); the verdict text lives in the store and
      // arrives through the usual reads — the active conversation reloads at
      // `BridgeReady`, the rest when opened. Only `Open` phases settle: a
      // `Starting` one belongs to a send still in flight, whose own
      // `started` (or failure) is coming.
      let settled = model.conversations.map(conv => {
        match conv.run {
          Open(run_id~, ..) if !live.contains(run_id) =>
            {
              ..conv.clear_streams().sweep_pending_steers(),
              run: NoRun(ended=None),
            }
          _ => conv
        }
      })
      (@cmd.none, { ..model, conversations: settled })
    }
    Engine(run_id, event, session~) => {
      // Compaction and background notices happen between turns, so their
      // events arrive after the run that owned `run_id` cleared
      // `active_run_id` — or with no run id at all (an engine spawned just
      // to compact). The host stamps them with their session, which covers
      // that case too; the conversation that last held the id remains the
      // fallback for unstamped events.
      let conv = if run_id is Some(id) &&
        model.conversation_by_run(id) is Some(conv) {
        Some(conv)
      } else if is_idle_event(event) {
        if session is Some(session) &&
          model.find_conversation(session) is Some(conv) {
          Some(conv)
        } else if run_id is Some(id) {
          model.conversation_by_last_run(id)
        } else {
          None
        }
      } else {
        None
      }
      if conv is Some(conv) {
        let (transcript_grew, next) = apply_engine_event(conv, event)
        (
          if transcript_grew {
            scroll_if_active(model, conv.session_id)
          } else {
            @cmd.none
          },
          model.replace_conversation(next),
        )
      } else {
        (@cmd.none, model)
      }
    }
    // Everything else the panel owns (tree, viewer, diagnostics) is the
    // fileeditor package's business; route it there and adopt its state.
    FileEditor(msg) => {
      let (cmd, panel) = @fileeditor.update(
        dispatch.map(msg => FileEditor(msg)),
        msg,
        model.file_panel,
        file_ctx(model),
      )
      (cmd, { ..model, file_panel: panel })
    }
    Failed(session~, message~) =>
      // The start request broke the turn the user just sent, so the error
      // belongs in that conversation's transcript.
      if model.find_conversation(session) is Some(conv) {
        let next = {
          ..conv
          .clear_streams()
          .sweep_pending_steers()
          .append_overlay(Assistant(true), message),
          run: NoRun(ended=Some(RunFailed)),
        }
        (
          @cmd.batch([
            scroll_if_active(model, session),
            fetch_sessions(dispatch),
          ]),
          model.replace_conversation(next),
        )
      } else {
        (@cmd.none, model)
      }
    SessionLoadFailed(session~, message~) =>
      // Only the newest selection may settle the loading marker; a failure
      // overtaken by a later click (or an abandoning New chat) is dropped.
      if model.loading_session != session {
        (@cmd.none, model)
      } else {
        // The sidebar may be listing sessions the store no longer has —
        // refresh it alongside the toast.
        let (toast, next) = model.notify_error(dispatch, message)
        (
          @cmd.batch([toast, fetch_sessions(dispatch)]),
          { ..next, loading_session: "" },
        )
      }
    HostActionFailed(message) => model.notify_error(dispatch, message)
    Error(run_id~, message~, diagnostics~) => {
      // A host error without a run belongs to whatever conversation the
      // user is looking at.
      let conv = if run_id is Some(run_id) {
        model.conversation_by_run(run_id)
      } else {
        Some(model.active())
      }
      if conv is Some(conv) {
        let content = if diagnostics is Some(diagnostics) &&
          !diagnostics.trim().is_empty() {
          message + "\n\n" + diagnostics
        } else {
          message
        }
        // Mid-run the error is transient — the host closes the run with its
        // own finished event moments later, and that verdict wins; only an
        // idle conversation keeps the error as how things stand.
        let next = conv.append_overlay(Assistant(true), content)
        (
          scroll_if_active(model, conv.session_id),
          model.replace_conversation(
            if next.run is NoRun(..) {
              { ..next, run: NoRun(ended=Some(RunErrored)) }
            } else {
              next
            },
          ),
        )
      } else {
        (@cmd.none, model)
      }
    }
    CompactRejected(session~, message~) =>
      if model.find_conversation(session) is Some(conv) {
        (
          scroll_if_active(model, conv.session_id),
          model.replace_conversation({
            ..conv.append_overlay(Assistant(true), message),
            compaction: NotCompacting,
          }),
        )
      } else {
        (@cmd.none, model)
      }
    Finished(run_id~, status~, answer~) =>
      if model.conversation_by_run(run_id) is Some(conv) {
        // In the normal path the engine settled every steer before this
        // terminal event; sweeping here only matters when the run died with
        // steers still in flight.
        let base = {
          ..conv.clear_streams().sweep_pending_steers(),
          run: NoRun(ended=Some(RunFinished(RunOutcome::parse(status)))),
          // A finish the user watched happen needs no reminder; one landing
          // in a background conversation leaves a dot until they visit.
          unseen_finish: conv.session_id != model.active_session,
        }
        let answer = answer.map(answer => answer.trim().to_owned())
        // The finished run just appended to the durable store, so the
        // sidebar list (and this conversation's title) may have changed —
        // and the turn may have created the repository or switched branches.
        let refresh = @cmd.batch([
          fetch_sessions(dispatch),
          fetch_branch(dispatch, conv.session_id, conv.cwd),
        ])
        if answer is Some(answer) && should_append_answer(conv, answer) {
          (
            @cmd.batch([scroll_if_active(model, conv.session_id), refresh]),
            model.replace_conversation(
              base.append_overlay(Assistant(false), answer),
            ),
          )
        } else {
          (refresh, model.replace_conversation(base))
        }
      } else {
        (@cmd.none, model)
      }
  }
}

// Purity and state-transition tests for the update handlers that back the
// streaming, session, and multi-conversation integration. Commands are
// opaque, so the tests assert on the returned model only.

///|
fn test_dispatch() -> @cmd.Emit[Msg] {
  Emit(_ => @cmd.none)
}

///|
fn test_conversation() -> Conversation {
  empty_conversation("desktop-test")
}

///|
fn running_conversation() -> Conversation {
  { ..test_conversation(), run: Open(run_id="r7", stage=Opened) }
}

///|
fn test_model() -> Model {
  {
    ..initial_model(),
    bridge: Connected,
    active_session: "desktop-test",
    conversations: [test_conversation()],
  }
}

///|
fn running_model() -> Model {
  test_model().replace_conversation(running_conversation())
}

///|
test "assistant deltas accumulate into the streaming response" {
  let dispatch = test_dispatch()
  let (_, first) = update(
    dispatch,
    Engine(Some("r7"), AssistantDelta("Hello"), session=None),
    running_model(),
  )
  let (_, second) = update(
    dispatch,
    Engine(Some("r7"), AssistantDelta(", world"), session=None),
    first,
  )
  inspect(second.active().streaming_response, content="Hello, world")
  inspect(second.active().messages.length(), content="0")
}

///|
test "update is pure: replaying a delta on the same model is idempotent" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    streaming_response: "partial",
  })
  let (_, once) = update(
    dispatch,
    Engine(Some("r7"), AssistantDelta("!"), session=None),
    model,
  )
  let (_, twice) = update(
    dispatch,
    Engine(Some("r7"), AssistantDelta("!"), session=None),
    model,
  )
  inspect(once.active().streaming_response, content="partial!")
  inspect(twice.active().streaming_response, content="partial!")
}

///|
test "deltas from an unknown run are dropped" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    Engine(Some("r99"), AssistantDelta("stale"), session=None),
    running_model(),
  )
  inspect(next.active().streaming_response, content="")
}

///|
test "reasoning message commits a thinking item and clears its stream" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    streaming_reasoning: "thinking…",
  })
  let (_, next) = update(
    dispatch,
    Engine(Some("r7"), ReasoningMessage("full thought"), session=None),
    model,
  )
  inspect(next.active().streaming_reasoning, content="")
  inspect(next.active().overlay.length(), content="1")
  guard next.active().overlay[0].kind is Reasoning else {
    fail("expected reasoning")
  }
  inspect(next.active().overlay[0].content, content="full thought")
}

///|
test "assistant message replaces the live stream with a committed item" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    streaming_response: "answ",
    streaming_reasoning: "thought",
  })
  let (_, next) = update(
    dispatch,
    Engine(Some("r7"), AssistantMessage("answer"), session=None),
    model,
  )
  inspect(next.active().streaming_response, content="")
  inspect(next.active().streaming_reasoning, content="")
  inspect(next.active().overlay.length(), content="1")
  inspect(next.active().overlay[0].content, content="answer")
}

///|
test "a new agent step clears both live streams" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    streaming_response: "left",
    streaming_reasoning: "over",
  })
  let (_, next) = update(
    dispatch,
    Engine(Some("r7"), AgentStep(Some(2)), session=None),
    model,
  )
  inspect(next.active().streaming_response, content="")
  inspect(next.active().streaming_reasoning, content="")
}

///|
test "finished run clears any leftover stream" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    streaming_response: "leftover",
  })
  let (_, next) = update(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("done")),
    model,
  )
  inspect(next.active().streaming_response, content="")
  inspect(next.active().is_running(), content="false")
}

///|
test "a finish the user watched leaves no unseen dot" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("done")),
    running_model(),
  )
  inspect(next.active().unseen_finish, content="false")
}

///|
test "a background finish marks its conversation until it is opened" {
  let dispatch = test_dispatch()
  // The run belongs to "desktop-test"; the user is looking at another chat.
  let model = { ..running_model(), active_session: "desktop-elsewhere" }
  let (_, next) = update(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("done")),
    model,
  )
  guard next.find_conversation("desktop-test") is Some(conv) else {
    fail("conversation missing")
  }
  inspect(conv.unseen_finish, content="true")
  let opened = next.activate("desktop-test")
  guard opened.find_conversation("desktop-test") is Some(seen) else {
    fail("conversation missing after activate")
  }
  inspect(seen.unseen_finish, content="false")
}

///|
test "an idle background notice routes by the last run id" {
  let dispatch = test_dispatch()
  // The run already finished: `active_run_id` is cleared, only the last-run
  // memory ties the id back to its conversation.
  let model = test_model().replace_conversation({
    ..test_conversation(),
    last_run_id: Some("r7"),
  })
  let notice = "[moon_check update]\nstatus=failed\nmain.mbt:1 error"
  let (_, next) = update(
    dispatch,
    Engine(Some("r7"), RuntimeUpdate(notice), session=None),
    model,
  )
  inspect(next.active().watcher_status, content="failed")
  guard next.active().overlay.get(0)
    is Some({ kind: Tool(name="moon_check failed", ..), .. }) else {
    fail("expected a runtime notice card")
  }
}

///|
test "new chat keeps the model intact until the rotation lands" {
  let dispatch = test_dispatch()
  let model = { ..running_model(), loading_session: "desktop-stale" }
  let (_, next) = update(dispatch, NewChat, model)
  inspect(next.active().is_running(), content="true")
  inspect(next.loading_session, content="")
}

///|
test "generated session ids include a random suffix" {
  let id = generated_session_id()
  let parts : Array[String] = id
    .split("-")
    .map(piece => piece.to_owned())
    .collect()
  inspect(parts.length(), content="5")
  inspect(parts[0], content="desktop")
  inspect(parts[1].length(), content="8")
  inspect(parts[2].length(), content="6")
  inspect(parts[3].length(), content="3")
  inspect(parts[4].length(), content="9")
  let _ = @string.parse_int(parts[1]) catch {
    _ => fail("expected numeric date")
  }
  let _ = @string.parse_int(parts[2]) catch {
    _ => fail("expected numeric time")
  }
  let _ = @string.parse_int(parts[3]) catch {
    _ => fail("expected numeric millis")
  }
  let _ = @string.parse_int(parts[4]) catch {
    _ => fail("expected numeric salt")
  }
}

///|
test "session rotation activates a fresh conversation, keeping the old one" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..running_conversation(),
    messages: [{ kind: User, content: "hi" }],
  })
  let (_, next) = update(dispatch, SessionRotated("desktop-fresh"), model)
  inspect(next.active_session, content="desktop-fresh")
  inspect(next.active().messages.length(), content="0")
  inspect(next.active().usage_tokens, content="0")
  assert_true(next.display_status() is Ready)
  // The previous conversation keeps running in the background.
  guard next.find_conversation("desktop-test") is Some(old) else {
    fail("expected the old conversation to survive")
  }
  inspect(old.is_running(), content="true")
  inspect(old.messages.length(), content="1")
}

///|
test "session rotation prunes abandoned empty conversations" {
  let dispatch = test_dispatch()
  let (_, first) = update(dispatch, SessionRotated("desktop-a"), test_model())
  let (_, second) = update(dispatch, SessionRotated("desktop-b"), first)
  // "desktop-test" and "desktop-a" had no transcript, no draft, no run.
  inspect(second.conversations.length(), content="1")
  inspect(second.active_session, content="desktop-b")
}

///|
test "sessions loaded replaces the sidebar list" {
  let dispatch = test_dispatch()
  let items : Array[@transcript.SessionListItem] = [
    {
      id: "desktop-a",
      title: Some("first question"),
      workspace: "",
      workspace_name: "",
    },
  ]
  let (_, once) = update(dispatch, SessionsLoaded(items), test_model())
  let (_, twice) = update(dispatch, SessionsLoaded(items), test_model())
  inspect(once.sessions.length(), content="1")
  inspect(once.sessions[0].id, content="desktop-a")
  inspect(twice.sessions.length(), content="1")
}

///|
test "sessions failure pops a toast without touching the transcript" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    messages: [{ kind: User, content: "hi" }],
  })
  let (_, next) = update(dispatch, SessionsFailed("engine exploded"), model)
  inspect(next.notifications.length(), content="1")
  inspect(
    next.notifications[0].message,
    content="Session list unavailable: engine exploded",
  )
  inspect(next.active().messages.length(), content="1")
}

///|
test "open session is a no-op for the current session" {
  let dispatch = test_dispatch()
  let (_, next) = update(dispatch, OpenSession("desktop-test"), test_model())
  inspect(next.active_session, content="desktop-test")
  inspect(next.conversations.length(), content="1")
}

///|
test "open session keeps live state on screen while re-reading the store" {
  let dispatch = test_dispatch()
  let background = {
    ..empty_conversation("desktop-bg"),
    run: Open(run_id="r9", stage=Opened),
    streaming_response: "mid-stream",
    messages: [{ kind: User, content: "background task" }],
  }
  let model = running_model().replace_conversation(background)
  let (_, once) = update(dispatch, OpenSession("desktop-bg"), model)
  let (_, twice) = update(dispatch, OpenSession("desktop-bg"), model)
  inspect(once.active_session, content="desktop-bg")
  // The live state stays on screen; the store re-read happens behind it
  // (this client may have been absent for part of this conversation).
  inspect(once.active().streaming_response, content="mid-stream")
  inspect(once.active().is_running(), content="true")
  inspect(once.loading_session, content="desktop-bg")
  // The previous conversation is still running in the background.
  guard once.find_conversation("desktop-test") is Some(old) else {
    fail("expected the old conversation to survive")
  }
  inspect(old.is_running(), content="true")
  inspect(twice.active_session, content="desktop-bg")
}

///|
test "open session tracks the latest load and ignores stale replies" {
  let dispatch = test_dispatch()
  let (_, loading_a) = update(dispatch, OpenSession("desktop-a"), test_model())
  inspect(loading_a.active_session, content="desktop-test")
  inspect(loading_a.loading_session, content="desktop-a")
  let (_, loading_b) = update(dispatch, OpenSession("desktop-b"), loading_a)
  inspect(loading_b.loading_session, content="desktop-b")
  let a_items : Array[@transcript.TranscriptItem] = [
    { kind: User, content: "old selection" },
  ]
  let (_, after_a) = update(
    dispatch,
    SessionLoaded(session="desktop-a", items=a_items, watermark=0),
    loading_b,
  )
  inspect(after_a.active_session, content="desktop-test")
  inspect(after_a.loading_session, content="desktop-b")
  let b_items : Array[@transcript.TranscriptItem] = [
    { kind: User, content: "latest selection" },
  ]
  let (_, after_b) = update(
    dispatch,
    SessionLoaded(session="desktop-b", items=b_items, watermark=0),
    after_a,
  )
  inspect(after_b.active_session, content="desktop-b")
  inspect(after_b.loading_session, content="")
  inspect(after_b.active().messages[0].content, content="latest selection")
}

///|
test "abandoned session load failures are dropped" {
  let dispatch = test_dispatch()
  let (_, loading) = update(dispatch, OpenSession("desktop-a"), test_model())
  let (_, abandoned) = update(dispatch, NewChat, loading)
  let (_, next) = update(
    dispatch,
    SessionLoadFailed(
      session="desktop-a",
      message="failed to load session desktop-a",
    ),
    abandoned,
  )
  inspect(next.loading_session, content="")
  inspect(next.active().messages.length(), content="0")
  inspect(next.notifications.length(), content="0")
}

///|
test "a live session load failure pops a toast, not a transcript bubble" {
  let dispatch = test_dispatch()
  let (_, loading) = update(dispatch, OpenSession("desktop-a"), test_model())
  let (_, next) = update(
    dispatch,
    SessionLoadFailed(
      session="desktop-a",
      message="failed to load session desktop-a: no such file",
    ),
    loading,
  )
  inspect(next.loading_session, content="")
  inspect(next.notifications.length(), content="1")
  inspect(
    next.notifications[0].message,
    content="failed to load session desktop-a: no such file",
  )
  // The conversation on screen keeps its transcript and status untouched.
  inspect(next.active().messages.length(), content="0")
  assert_true(next.display_status() is Ready)
}

///|
test "a host action failure pops a toast" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    HostActionFailed("open path failed: no opener"),
    test_model(),
  )
  inspect(next.notifications.length(), content="1")
  inspect(next.notifications[0].message, content="open path failed: no opener")
}

///|
test "session loaded swaps the active conversation onto the stored session" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model().replace_conversation({
      ..test_conversation(),
      usage_tokens: 42,
      watcher_status: "running",
      streaming_response: "leftover",
      messages: [{ kind: User, content: "old chat" }],
    }),
    loading_session: "desktop-stored",
  }
  let items : Array[@transcript.TranscriptItem] = [
    { kind: User, content: "stored question" },
    { kind: Assistant(false), content: "stored answer" },
  ]
  let (_, once) = update(
    dispatch,
    SessionLoaded(session="desktop-stored", items~, watermark=0),
    model,
  )
  let (_, twice) = update(
    dispatch,
    SessionLoaded(session="desktop-stored", items~, watermark=0),
    model,
  )
  inspect(once.active_session, content="desktop-stored")
  inspect(once.active().messages.length(), content="2")
  inspect(once.active().messages[0].content, content="stored question")
  inspect(once.active().streaming_response, content="")
  inspect(once.active().usage_tokens, content="0")
  inspect(once.active().watcher_status, content="")
  assert_true(once.active().cwd is None)
  assert_true(once.display_status() is Ready)
  inspect(twice.active().messages.length(), content="2")
}

///|
test "session loaded adopts the store transcript and keeps live run state" {
  let dispatch = test_dispatch()
  let model = { ..running_model(), loading_session: "desktop-stored" }
  let items : Array[@transcript.TranscriptItem] = [
    { kind: User, content: "stored" },
  ]
  // The active conversation runs; loading some other stored session is fine.
  let (_, other) = update(
    dispatch,
    SessionLoaded(session="desktop-stored", items~, watermark=0),
    model,
  )
  inspect(other.active_session, content="desktop-stored")
  guard other.find_conversation("desktop-test") is Some(live) else {
    fail("expected the running conversation to survive")
  }
  inspect(live.is_running(), content="true")
  // A load reply for the running conversation itself adopts the store's
  // transcript — the source of truth for completed items — while the live
  // run state (phase, streaming buffers) rides across untouched.
  let streaming = running_model().replace_conversation({
    ..running_conversation(),
    streaming_response: "mid-step",
  })
  let (_, same) = update(
    dispatch,
    SessionLoaded(session="desktop-test", items~, watermark=0),
    { ..streaming, loading_session: "desktop-test" },
  )
  inspect(same.active().messages.length(), content="1")
  inspect(same.active().messages[0].content, content="stored")
  inspect(same.active().is_running(), content="true")
  inspect(same.active().streaming_response, content="mid-step")
}

///|
test "started routes by session and records the host's workspace" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    Started(
      run_id="r7",
      session="desktop-test",
      model="deepseek-v4-pro",
      max_steps=1000,
      cwd=Some(Absolute("/home/u/Documents/OpenSeek/desktop-test")),
      task=None,
    ),
    test_model(),
  )
  assert_true(
    next.active().cwd
    is Some(Absolute("/home/u/Documents/OpenSeek/desktop-test")),
  )
  inspect(next.active().is_running(), content="true")
  guard next.active().run is Open(run_id="r7", ..) else {
    fail("expected the run id to be recorded")
  }
  // A run this client did not send: the store gained its prompt, so the
  // on-screen conversation re-reads it in the background, buffering commits
  // until the snapshot lands. The user-load marker stays free.
  assert_true(next.active().sync is Reloading(..))
  inspect(next.loading_session, content="")
}

///|
test "started for an unknown session materializes its conversation" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    Started(
      run_id="r7",
      session="desktop-ghost",
      model="deepseek-v4-pro",
      max_steps=1000,
      cwd=None,
      task=Some("fix the flaky test"),
    ),
    test_model(),
  )
  // Another client's run is now trackable here: cancellable, steerable,
  // and its events route to a real conversation.
  guard next.find_conversation("desktop-ghost") is Some(ghost) else {
    fail("expected the foreign run's conversation to materialize")
  }
  inspect(ghost.is_running(), content="true")
  guard ghost.run is Open(run_id="r7", ..) else {
    fail("expected the run id to be recorded")
  }
  // No bubble is synthesized from the pushed task — the durable transcript's
  // only sources are snapshots and commits, and the prompt's own commit (or
  // the read when this conversation is opened) brings it.
  inspect(ghost.messages.length(), content="0")
  inspect(ghost.overlay.length(), content="0")
  // Focus stays where the user is.
  inspect(next.active_session, content="desktop-test")
  inspect(next.active().is_running(), content="false")
}

///|
test "runs settled closes runs the host no longer has, sparing live and starting ones" {
  let dispatch = test_dispatch()
  // A run that ended while this client was away: its terminal event is
  // gone for good, so only the `agent.runs` reply can close it.
  let stale = {
    ..empty_conversation("desktop-stale"),
    run: Open(run_id="r9", stage=AtStep(Some(4))),
    streaming_response: "mid-step",
  }
  // A send still in flight has no run id yet; its own `started` (or
  // failure) is coming and must be the one to settle it.
  let starting = { ..empty_conversation("desktop-starting"), run: Starting }
  let model = running_model()
    .replace_conversation(stale)
    .replace_conversation(starting)
  let (_, next) = update(dispatch, RunsSettled(live=["r7"]), model)
  // Run 7 is still in flight on the host: untouched.
  inspect(next.active().is_running(), content="true")
  guard next.find_conversation("desktop-stale") is Some(settled) else {
    fail("expected the stale conversation")
  }
  inspect(settled.is_running(), content="false")
  inspect(settled.streaming_response, content="")
  guard settled.run is NoRun(ended=None) else {
    fail("expected the stale run to settle without a verdict")
  }
  guard next.find_conversation("desktop-starting") is Some(sending) else {
    fail("expected the starting conversation")
  }
  assert_true(sending.run is Starting)
}

///|
test "concurrent conversations keep their streams apart" {
  let dispatch = test_dispatch()
  let second = {
    ..empty_conversation("desktop-second"),
    run: Open(run_id="r8", stage=Opened),
  }
  let model = running_model().replace_conversation(second)
  let (_, next) = update(
    dispatch,
    Engine(Some("r8"), AssistantDelta("for B"), session=None),
    model,
  )
  // Run 8 belongs to the background conversation; the active one is untouched.
  inspect(next.active().streaming_response, content="")
  guard next.find_conversation("desktop-second") is Some(bg) else {
    fail("expected the background conversation")
  }
  inspect(bg.streaming_response, content="for B")
}

///|
test "a background run finishes without disturbing the conversation on screen" {
  let dispatch = test_dispatch()
  let second = {
    ..empty_conversation("desktop-second"),
    run: Open(run_id="r8", stage=Opened),
    messages: [{ kind: User, content: "background ask" }],
  }
  let model = running_model().replace_conversation(second)
  let (_, next) = update(
    dispatch,
    Finished(run_id="r8", status="finished", answer=Some("done")),
    model,
  )
  guard next.find_conversation("desktop-second") is Some(bg) else {
    fail("expected the background conversation")
  }
  inspect(bg.is_running(), content="false")
  assert_true(bg.run is NoRun(ended=Some(RunFinished(_))))
  inspect(bg.overlay[0].content, content="done")
  // The conversation on screen is still running its own turn.
  inspect(next.active().is_running(), content="true")
  assert_true(next.display_status() is Running)
}

///|
test "send while running queues a steer instead of a prompt" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    task: "focus on the tests",
  })
  let (_, once) = update(dispatch, Send, model)
  let (_, twice) = update(dispatch, Send, model)
  inspect(once.active().task, content="")
  inspect(once.active().pending_steers.length(), content="1")
  inspect(once.active().pending_steers[0], content="focus on the tests")
  // The steer is pending, not part of the transcript yet.
  inspect(once.active().messages.length(), content="0")
  inspect(once.active().is_running(), content="true")
  inspect(twice.active().pending_steers.length(), content="1")
  inspect(twice.active().pending_steers[0], content="focus on the tests")
}

///|
test "a cancelling turn cannot be steered; the text stays in the composer" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    run: Open(run_id="r7", stage=Cancelling),
    task: "too late",
  })
  let (_, next) = update(dispatch, Send, model)
  inspect(next.active().task, content="too late")
  inspect(next.active().pending_steers.length(), content="0")
}

///|
test "the composer draft stays with its conversation across a switch" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..empty_conversation("desktop-second"),
    messages: [{ kind: User, content: "earlier" }],
  })
  let (_, drafted) = update(dispatch, TaskChanged("half a thought"), model)
  let (_, switched) = update(dispatch, OpenSession("desktop-second"), drafted)
  // The other conversation starts with its own (empty) draft …
  inspect(switched.active().task, content="")
  let (_, back) = update(dispatch, OpenSession("desktop-test"), switched)
  // … and the original draft is still waiting where it was typed.
  inspect(back.active().task, content="half a thought")
}

///|
test "steer_applied commits the pending steer as a user message" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    pending_steers: ["go left"],
  })
  let (_, next) = update(
    dispatch,
    Engine(Some("r7"), SteerApplied("go left"), session=None),
    model,
  )
  inspect(next.active().pending_steers.length(), content="0")
  inspect(next.active().overlay.length(), content="1")
  guard next.active().overlay[0].kind is User else {
    fail("expected a user item")
  }
  inspect(next.active().overlay[0].content, content="go left")
}

///|
test "steer_dropped settles the pending steer with a visible notice" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    pending_steers: ["go left"],
  })
  let (_, next) = update(
    dispatch,
    Engine(Some("r7"), SteerDropped("go left"), session=None),
    model,
  )
  inspect(next.active().pending_steers.length(), content="0")
  inspect(next.active().overlay.length(), content="1")
  guard next.active().overlay[0].kind is Assistant(true) else {
    fail("expected an error bubble")
  }
  assert_true(next.active().overlay[0].content.contains("go left"))
}

///|
test "an identical-text settle removes exactly one pending entry" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    pending_steers: ["again", "again"],
  })
  let (_, next) = update(
    dispatch,
    Engine(Some("r7"), SteerApplied("again"), session=None),
    model,
  )
  inspect(next.active().pending_steers.length(), content="1")
  inspect(next.active().pending_steers[0], content="again")
  inspect(next.active().overlay.length(), content="1")
}

///|
test "an undelivered steer is reported instead of vanishing" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    pending_steers: ["lost"],
  })
  let (_, next) = update(
    dispatch,
    SteerUndelivered(session="desktop-test", text="lost"),
    model,
  )
  inspect(next.active().pending_steers.length(), content="0")
  inspect(next.active().overlay.length(), content="1")
  guard next.active().overlay[0].kind is Assistant(true) else {
    fail("expected an error bubble")
  }
  assert_true(next.active().overlay[0].content.contains("lost"))
}

///|
test "a run that ends with steers in flight sweeps them into notices" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    pending_steers: ["orphaned"],
  })
  let (_, next) = update(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("")),
    model,
  )
  inspect(next.active().pending_steers.length(), content="0")
  inspect(next.active().is_running(), content="false")
  guard next.active().overlay[0].kind is Assistant(true) else {
    fail("expected an error bubble")
  }
  assert_true(next.active().overlay[0].content.contains("orphaned"))
}

///|
test "late undelivered steer is dropped after run-end sweep" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    pending_steers: ["lost"],
  })
  let (_, finished) = update(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("")),
    model,
  )
  let (_, next) = update(
    dispatch,
    SteerUndelivered(session="desktop-test", text="lost"),
    finished,
  )
  inspect(next.active().pending_steers.length(), content="0")
  inspect(next.active().overlay.length(), content="1")
  assert_true(next.active().overlay[0].content.contains("lost"))
}

///|
test "the default provider needs no API key to be ready" {
  let model = test_model()
  assert_false(model.deepseek_key_saved)
  assert_true(model.api_ready())
}

///|
test "the official endpoint requires a key, a custom endpoint a URL" {
  let official = { ..test_model(), api_provider: Deepseek }
  assert_false(official.api_ready())
  assert_true(official.display_status() is ApiKeyRequired)
  assert_true({ ..official, deepseek_key_saved: true }.api_ready())
  let custom = { ..test_model(), api_provider: Custom, custom_api_url: "" }
  assert_false(custom.api_ready())
  assert_true(custom.display_status() is SetupRequired)
  let configured = {
    ..custom,
    custom_api_url: "https://proxy.example/chat/completions",
  }
  assert_true(configured.api_ready())
}

///|
test "loaded UI preferences parse their wire names" {
  let dispatch = test_dispatch()
  let (_, restored) = update(
    dispatch,
    SettingsLoaded(
      notification_corner="top-left",
      tree_layout="",
      update_channel="staging",
    ),
    test_model(),
  )
  assert_true(restored.notification_corner is TopLeft)
  assert_true(restored.update_channel is Staging)
  // Unknown stored values fall back to the defaults.
  let (_, unknown) = update(
    dispatch,
    SettingsLoaded(notification_corner="", tree_layout="", update_channel=""),
    test_model(),
  )
  assert_true(unknown.notification_corner is BottomRight)
  assert_true(unknown.update_channel is Production)
}

///|
fn host_settings(
  provider~ : String,
  has_deepseek_key? : Bool = false,
  wsl_enabled? : Bool = false,
  wsl_distro? : String = "",
  wsl_engine? : String = "",
) -> HostSettings {
  {
    provider,
    custom_api_url: "",
    has_deepseek_key,
    has_custom_key: false,
    wsl_enabled,
    wsl_distro,
    wsl_engine,
  }
}

///|
test "host settings open the settings page only when incomplete" {
  let dispatch = test_dispatch()
  let (_, zero_config) = update(
    dispatch,
    HostSettingsLoaded(host_settings(provider="openseek")),
    test_model(),
  )
  assert_true(zero_config.screen is Chat)
  assert_true(zero_config.api_provider is Openseek)
  assert_true(zero_config.display_status() is Ready)
  let (_, keyless) = update(
    dispatch,
    HostSettingsLoaded(host_settings(provider="deepseek")),
    test_model(),
  )
  assert_true(keyless.screen is Settings)
  assert_true(keyless.display_status() is ApiKeyRequired)
  let (_, restored) = update(
    dispatch,
    HostSettingsLoaded(
      host_settings(
        provider="deepseek",
        has_deepseek_key=true,
        wsl_enabled=true,
        wsl_distro="Ubuntu",
        wsl_engine="/usr/local/bin/openseek",
      ),
    ),
    test_model(),
  )
  assert_true(restored.screen is Chat)
  assert_true(restored.deepseek_key_saved)
  inspect(restored.wsl_enabled, content="true")
  inspect(restored.wsl_distro, content="Ubuntu")
  inspect(restored.wsl_engine, content="/usr/local/bin/openseek")
}

///|
test "host settings are dropped while this client's writes are in flight" {
  let dispatch = test_dispatch()
  let model = { ..test_model(), settings_saves: 1 }
  // A broadcast (or a stale get reply) arriving mid-write must not clobber
  // the optimistic mirror.
  let (_, ignored) = update(
    dispatch,
    HostSettingsLoaded(host_settings(provider="deepseek")),
    model,
  )
  assert_true(ignored.api_provider is Openseek)
  inspect(ignored.settings_saves, content="1")
  // The write's own reply reconciles once it is the last one out.
  let (_, settled) = update(
    dispatch,
    HostSettingsApplied(
      host_settings(provider="deepseek", has_deepseek_key=true),
    ),
    model,
  )
  inspect(settled.settings_saves, content="0")
  assert_true(settled.api_provider is Deepseek)
  assert_true(settled.deepseek_key_saved)
  // With more writes still out, even a reply only decrements.
  let stacked = { ..model, settings_saves: 2 }
  let (_, still_pending) = update(
    dispatch,
    HostSettingsApplied(host_settings(provider="deepseek")),
    stacked,
  )
  inspect(still_pending.settings_saves, content="1")
  assert_true(still_pending.api_provider is Openseek)
}

///|
test "legacy client settings migrate up only from the desktop window" {
  let dispatch = test_dispatch()
  let legacy = LegacySettingsRead(
    provider="deepseek",
    custom_url="",
    api_key="sk-legacy",
    custom_api_key="",
    wsl_enabled="1",
    wsl_distro="Ubuntu",
    wsl_engine="",
  )
  let (_, desktop) = update(dispatch, legacy, {
    ..test_model(),
    is_desktop: true,
  })
  assert_true(desktop.api_provider is Deepseek)
  assert_true(desktop.deepseek_key_saved)
  inspect(desktop.wsl_distro, content="Ubuntu")
  inspect(desktop.settings_saves, content="1")
  assert_true(desktop.legacy_cleanup_pending)
  // A browser page only purges — its copy may belong to another device.
  let (_, browser) = update(dispatch, legacy, {
    ..test_model(),
    is_desktop: false,
  })
  assert_false(browser.deepseek_key_saved)
  inspect(browser.settings_saves, content="0")
  assert_false(browser.legacy_cleanup_pending)
}

///|
test "the notification-corner setting parses its wire names" {
  let dispatch = test_dispatch()
  let (_, moved) = update(
    dispatch,
    NotificationCornerChanged("top-right"),
    test_model(),
  )
  assert_true(moved.notification_corner is TopRight)
  let (_, unknown) = update(
    dispatch,
    NotificationCornerChanged("nowhere"),
    moved,
  )
  assert_true(unknown.notification_corner is BottomRight)
}

///|
test "the tree-layout setting parses its wire names" {
  let dispatch = test_dispatch()
  let (_, docked) = update(
    dispatch,
    TreeLayoutChanged("bottom-panel"),
    test_model(),
  )
  assert_true(docked.tree_layout is BottomPanel)
  // An unknown stored value falls back to the default right sidebar.
  let (_, unknown) = update(dispatch, TreeLayoutChanged("floating"), docked)
  assert_true(unknown.tree_layout is RightSidebar)
}

///|
test "update is pure: a provider change is idempotent" {
  let dispatch = test_dispatch()
  let model = { ..test_model(), setup_api_key: "typed" }
  let (_, once) = update(dispatch, ProviderChanged("deepseek"), model)
  let (_, twice) = update(dispatch, ProviderChanged("deepseek"), model)
  assert_true(once.api_provider is Deepseek)
  assert_true(twice.api_provider is Deepseek)
  inspect(once.setup_api_key, content="")
  inspect(twice.setup_api_key, content="")
  inspect(once.settings_saves, content="1")
  inspect(twice.settings_saves, content="1")
  assert_true(once.display_status() is ApiKeyRequired)
  assert_true(twice.display_status() is ApiKeyRequired)
}

///|
test "saving a key marks the active provider credential only" {
  let dispatch = test_dispatch()
  let deepseek = {
    ..test_model(),
    api_provider: Deepseek,
    setup_api_key: "  sk-new  ",
    screen: Settings,
  }
  let (_, saved_deepseek) = update(dispatch, SaveApiKey, deepseek)
  assert_true(saved_deepseek.deepseek_key_saved)
  assert_false(saved_deepseek.custom_key_saved)
  inspect(saved_deepseek.setup_api_key, content="")
  inspect(saved_deepseek.settings_saves, content="1")
  assert_true(saved_deepseek.screen is Chat)
  let custom = {
    ..deepseek,
    api_provider: Custom,
    custom_api_url: "https://proxy.example/chat/completions",
    setup_api_key: "  sk-custom-new  ",
  }
  let (_, saved_custom) = update(dispatch, SaveApiKey, custom)
  assert_false(saved_custom.deepseek_key_saved)
  assert_true(saved_custom.custom_key_saved)
  assert_true(saved_custom.screen is Chat)
}

///|
test "changing settings mid-run leaves the run status alone" {
  let dispatch = test_dispatch()
  let (_, next) = update(dispatch, ProviderChanged("deepseek"), running_model())
  assert_true(next.display_status() is Running)
  assert_true(next.api_provider is Deepseek)
}

///|
/// The Settings page has no Done button — the sidebar is the only way out,
/// even while the endpoint is unusable (the composer blocks sending then).
test "sidebar navigation leaves the settings page" {
  let dispatch = test_dispatch()
  let model = { ..test_model(), api_provider: Deepseek, screen: Settings }
  let (_, next) = update(dispatch, SessionRotated("s-fresh"), model)
  assert_true(next.screen is Chat)
}

///|
test "the scroll watcher's report lands on the model" {
  let dispatch = test_dispatch()
  let (_, away) = update(dispatch, TranscriptPinned(false), test_model())
  inspect(away.transcript_pinned, content="false")
  let (_, back) = update(dispatch, TranscriptPinned(true), away)
  inspect(back.transcript_pinned, content="true")
}

///|
test "a branch reply lands on its conversation and an empty one hides it" {
  let dispatch = test_dispatch()
  let (_, named) = update(
    dispatch,
    BranchLoaded(session="desktop-test", branch=Some("feature/x")),
    test_model(),
  )
  assert_true(named.active().branch is Some("feature/x"))
  let (_, cleared) = update(
    dispatch,
    BranchLoaded(session="desktop-test", branch=Some("")),
    named,
  )
  assert_true(cleared.active().branch is Some(""))
  // A reply for an unknown session is dropped.
  let (_, ignored) = update(
    dispatch,
    BranchLoaded(session="desktop-gone", branch=Some("main")),
    test_model(),
  )
  assert_true(ignored.active().branch is None)
}

///|
fn archived_item(id : String) -> @transcript.SessionListItem {
  { id, title: Some(""), workspace: "", workspace_name: "" }
}

///|
test "an archived background session drops its live state, active stays" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model(),
    conversations: [test_conversation(), empty_conversation("desktop-old")],
  }
  let (_, next) = update(
    dispatch,
    ArchivedLoaded([archived_item("desktop-old")]),
    model,
  )
  inspect(next.archived.length(), content="1")
  inspect(next.archived[0].id, content="desktop-old")
  assert_true(next.find_conversation("desktop-old") is None)
  inspect(next.active_session, content="desktop-test")
}

///|
test "archiving the active conversation clears it for the rotation" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    ArchivedLoaded([archived_item("desktop-test")]),
    test_model(),
  )
  assert_true(next.find_conversation("desktop-test") is None)
  inspect(next.archived[0].id, content="desktop-test")
}

///|
test "an archive failure pops a toast that a click or its timer dismisses" {
  let dispatch = test_dispatch()
  let (_, failed) = update(dispatch, ArchiveFailed("zip missing"), test_model())
  inspect(failed.notifications.length(), content="1")
  inspect(
    failed.notifications[0].message,
    content="Archive failed: zip missing",
  )
  let id = failed.notifications[0].id
  // A stale timer (the toast is already gone) must not touch a later toast.
  let (_, dismissed) = update(dispatch, DismissNotification(id), failed)
  inspect(dismissed.notifications.length(), content="0")
  let (_, again) = update(dispatch, ArchiveFailed("still missing"), dismissed)
  let (_, expired) = update(dispatch, NotificationExpired(id), again)
  inspect(expired.notifications.length(), content="1")
  inspect(
    expired.notifications[0].message,
    content="Archive failed: still missing",
  )
}

///|
test "toast ids only ever grow, so timers and toasts stay paired" {
  let dispatch = test_dispatch()
  let (_, first) = update(dispatch, ArchiveFailed("one"), test_model())
  let (_, second) = update(dispatch, SessionsFailed("two"), first)
  inspect(second.notifications.length(), content="2")
  assert_true(second.notifications[0].id != second.notifications[1].id)
  inspect(second.notification_seq, content="2")
}

///|
test "the color-scheme watcher's report lands on the model" {
  let dispatch = test_dispatch()
  let (_, dark) = update(dispatch, ColorSchemeChanged(true), test_model())
  inspect(dark.dark_mode, content="true")
  let (_, light) = update(dispatch, ColorSchemeChanged(false), dark)
  inspect(light.dark_mode, content="false")
}

///|
test "update is pure: a pinned-state change is idempotent" {
  let dispatch = test_dispatch()
  let (_, first) = update(dispatch, TranscriptPinned(false), test_model())
  let (_, second) = update(dispatch, TranscriptPinned(false), test_model())
  inspect(first.transcript_pinned, content="false")
  inspect(second.transcript_pinned, content="false")
}

///|
test "an unpinned transcript stays unpinned while a stream grows" {
  // The pinned flag is the scroll gate; a delta to the active conversation
  // must not flip it back, or the next render would yank the reader down.
  let dispatch = test_dispatch()
  let model = { ..running_model(), transcript_pinned: false }
  let (_, next) = update(
    dispatch,
    Engine(Some("r7"), AssistantDelta("more"), session=None),
    model,
  )
  inspect(next.transcript_pinned, content="false")
  inspect(next.active().streaming_response, content="more")
}

///|
test "explicit user actions re-pin the transcript" {
  let dispatch = test_dispatch()

  // Sending a prompt jumps to the tail.
  let unpinned = {
    ..test_model().replace_conversation({ ..test_conversation(), task: "do it" }),
    transcript_pinned: false,
  }
  let (_, sent) = update(dispatch, Send, unpinned)
  inspect(sent.transcript_pinned, content="true")

  // Steering a running turn does too.
  let steering = {
    ..running_model().replace_conversation({
      ..running_conversation(),
      task: "and this",
    }),
    transcript_pinned: false,
  }
  let (_, steered) = update(dispatch, Send, steering)
  inspect(steered.transcript_pinned, content="true")

  // Switching to a conversation that has live state lands at its tail.
  let two = {
    ..test_model().replace_conversation(empty_conversation("desktop-other")),
    transcript_pinned: false,
  }
  let (_, switched) = update(dispatch, OpenSession("desktop-other"), two)
  inspect(switched.transcript_pinned, content="true")

  // So does loading a stored session or rotating to a fresh one.
  let (_, loaded) = update(
    dispatch,
    SessionLoaded(session="desktop-old", items=[], watermark=0),
    { ..test_model(), transcript_pinned: false, loading_session: "desktop-old" },
  )
  inspect(loaded.transcript_pinned, content="true")
  let (_, rotated) = update(dispatch, SessionRotated("desktop-fresh"), {
    ..test_model(),
    transcript_pinned: false,
  })
  inspect(rotated.transcript_pinned, content="true")
}

///|
fn test_market_item() -> @transcript.MarketSkillItem {
  {
    name: "acme/widget",
    module_name: "acme/widget",
    package_path: "",
    version: "1.0.0",
    description: "Build widgets fast.",
    author: "acme",
    repository: "",
  }
}

///|
test "opening the skills page fetches the catalog once" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, OpenSkills, test_model())
  assert_true(opened.screen is Skills)
  assert_true(opened.skills_catalog is CatalogLoading)

  // Reopening with a loaded catalog keeps it; only a failure refetches.
  let loaded = { ..test_model(), skills_catalog: CatalogReady([]) }
  let (_, reopened) = update(dispatch, OpenSkills, loaded)
  assert_true(reopened.skills_catalog is CatalogReady(_))
  let failed = {
    ..test_model(),
    skills_catalog: CatalogFailed("offline"),
    skills_notice: "stale",
  }
  let (_, retried) = update(dispatch, OpenSkills, failed)
  assert_true(retried.skills_catalog is CatalogLoading)
  inspect(retried.skills_notice, content="")
}

///|
test "selecting a conversation returns from the skills page to the chat" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, OpenSkills, test_model())
  assert_true(opened.screen is Skills)

  // Re-selecting the active conversation is enough to switch back…
  let (_, back) = update(dispatch, OpenSession("desktop-test"), opened)
  assert_true(back.screen is Chat)

  // …and so is rotating to a fresh one.
  let (_, rotated) = update(dispatch, SessionRotated("desktop-fresh"), opened)
  assert_true(rotated.screen is Chat)
}

///|
test "update is pure: opening the skills page twice is idempotent" {
  let dispatch = test_dispatch()
  let model = test_model()
  let (_, once) = update(dispatch, OpenSkills, model)
  let (_, twice) = update(dispatch, OpenSkills, model)
  assert_true(once.screen is Skills)
  assert_true(twice.screen is Skills)
  assert_true(once.skills_catalog is CatalogLoading)
  assert_true(twice.skills_catalog is CatalogLoading)
}

///|
test "the skills search query lands on the model" {
  let dispatch = test_dispatch()
  let (_, typed) = update(dispatch, SkillsQueryChanged("widget"), test_model())
  inspect(typed.skills_query, content="widget")
}

///|
test "an install marks its entry busy exactly once" {
  let dispatch = test_dispatch()
  let (_, busy) = update(
    dispatch,
    InstallSkill(test_market_item()),
    test_model(),
  )
  inspect(busy.skills_busy.length(), content="1")
  inspect(busy.skills_busy[0], content="acme/widget@1.0.0")

  // A second click while in flight is a no-op.
  let (_, again) = update(dispatch, InstallSkill(test_market_item()), busy)
  inspect(again.skills_busy.length(), content="1")
}

///|
test "a settled action releases its busy entry" {
  let dispatch = test_dispatch()
  let busy = { ..test_model(), skills_busy: ["acme/widget@1.0.0", "other"] }
  let (_, done) = update(
    dispatch,
    SkillActionDone(key="acme/widget@1.0.0", error=""),
    busy,
  )
  inspect(done.skills_busy.length(), content="1")
  inspect(done.skills_busy[0], content="other")
  inspect(done.skills_notice, content="")

  // A failure surfaces as the panel notice instead.
  let (_, failed) = update(
    dispatch,
    SkillActionDone(key="other", error="digest mismatch"),
    done,
  )
  inspect(failed.skills_busy.length(), content="0")
  inspect(failed.skills_notice, content="digest mismatch")
}

///|
test "uninstall is keyed by the library id and deduplicated" {
  let dispatch = test_dispatch()
  let (_, busy) = update(dispatch, UninstallSkill("acme-widget"), test_model())
  inspect(busy.skills_busy.length(), content="1")
  inspect(busy.skills_busy[0], content="acme-widget")
  let (_, again) = update(dispatch, UninstallSkill("acme-widget"), busy)
  inspect(again.skills_busy.length(), content="1")
}

///|
test "catalog and library replies land on the model" {
  let dispatch = test_dispatch()
  let (_, ready) = update(
    dispatch,
    SkillsCatalogLoaded([test_market_item()]),
    test_model(),
  )
  guard ready.skills_catalog is CatalogReady(items) else {
    fail("catalog should be ready")
  }
  inspect(items.length(), content="1")
  assert_false(ready.skill_installed("acme/widget@1.0.0"))
  let (_, failed) = update(dispatch, SkillsCatalogFailed("offline"), ready)
  assert_true(failed.skills_catalog is CatalogFailed(_))
  let installed : Array[@transcript.InstalledSkillItem] = [
    {
      id: "acme-widget",
      name: "widget",
      description: "",
      source: "acme/widget@1.0.0",
    },
  ]
  let (_, listed) = update(dispatch, InstalledSkillsLoaded(installed), ready)
  assert_true(listed.skill_installed("acme/widget@1.0.0"))
  let (_, noticed) = update(
    dispatch,
    SkillsNotice("library unreadable"),
    listed,
  )
  inspect(noticed.skills_notice, content="library unreadable")
}

///|
test "JumpToMention opens the editor panel and selects the mention's file" {
  let dispatch = test_dispatch()
  let mention : Mention = {
    ref_: Symbol(name="parse_hover", file="src/main.mbt", line=5),
    range: Some(@common.Range::Range(5, 1, 5, 12)),
  }
  let model = test_model().replace_conversation({
    ..test_conversation(),
    mentions: [mention],
  })
  let (_, next) = update(dispatch, JumpToMention(0), model)
  assert_true(next.file_panel.open)
  assert_true(next.file_panel.active is Some(Relative("src/main.mbt")))
}

///|
test "JumpToMention is a no-op for a chip without a resolved location" {
  let dispatch = test_dispatch()
  let mention : Mention = { ref_: Skill(name="review-pr"), range: None }
  let model = test_model().replace_conversation({
    ..test_conversation(),
    mentions: [mention],
  })
  let (_, next) = update(dispatch, JumpToMention(0), model)
  assert_false(next.file_panel.open)
  assert_true(next.file_panel.active is None)
}

///|
test "EditorCommentAdded attaches a deduplicated annotation chip" {
  let dispatch = test_dispatch()
  let model = test_model()
  // The chip path arrives workspace-relative from the panel (recorded when
  // the file was shown); the resource URI only routes the bubble removal.
  let msg : Msg = FileEditor(
    EditorCommentAdded(
      resource=@fileeditor.ModelUri::of(Absolute("/work/project/src/main.mbt")),
      file=Relative("src/main.mbt"),
      range=@common.Range::Range(5, 1, 6, 3),
      quote="fn parse_hover() {",
      comment="rename this",
      feedback_id="viewer-feedback-0",
    ),
  )
  let (_, next) = update(dispatch, msg, model)
  let mentions = next.active().mentions
  assert_eq(mentions.length(), 1)
  assert_true(
    mentions[0].ref_
    is Annotation(file="src/main.mbt", start_line=5, end_line=6, ..),
  )
  // Submitting the identical comment again is a no-op, not a second chip.
  let (_, again) = update(dispatch, msg, next)
  assert_eq(again.active().mentions.length(), 1)
}

///|
test "chip jumps relativize legacy absolute paths against the roots" {
  let dispatch = test_dispatch()
  // Preferred root: the run-reported cwd.
  let model = test_model().replace_conversation({
    ..test_conversation(),
    cwd: Some(Absolute("/work/project")),
  })
  let (_, next) = update(
    dispatch,
    JumpToLocation(
      path="/work/project/src/main.mbt",
      range=Some(@common.Range::Range(5, 1, 5, 1)),
      annotation=None,
    ),
    model,
  )
  assert_true(next.file_panel.active is Some(Relative("src/main.mbt")))
  // Before the first run reports cwd, the attached workspace serves as root.
  let model = test_model().replace_conversation({
    ..test_conversation(),
    workspace: Some(Absolute("/work/project")),
  })
  let (_, next) = update(
    dispatch,
    JumpToLocation(
      path="/work/project/src/main.mbt",
      range=Some(@common.Range::Range(5, 1, 5, 1)),
      annotation=None,
    ),
    model,
  )
  assert_true(next.file_panel.active is Some(Relative("src/main.mbt")))
  // An absolute path outside every root cannot be opened; the panel says so
  // instead of sending the host a bogus read.
  let (_, outside) = update(
    dispatch,
    JumpToLocation(
      path="/elsewhere/note.md",
      range=Some(@common.Range::Range(1, 1, 1, 1)),
      annotation=None,
    ),
    model,
  )
  assert_true(outside.file_panel.active is None)
  assert_false(outside.file_panel.error.is_empty())
}

///|
test "RevealDirectory(\"\") opens the tree pane without a highlight" {
  let dispatch = test_dispatch()
  let model = test_model()
  let panel = {
    ..model.file_panel,
    open: true,
    session: "desktop-test",
    tree_open: false,
    active: Some(Relative("README.md")),
    highlighted: Some(Relative("src")),
  }
  let (_, next) = update(
    dispatch,
    FileEditor(RevealDirectory(@pathx.Relative::root())),
    { ..model, file_panel: panel },
  )
  // The active tab stays put — revealing the tree must not close the file.
  assert_true(next.file_panel.active is Some(Relative("README.md")))
  assert_true(next.file_panel.tree_open)
  assert_true(next.file_panel.highlighted is None)
}

///|
test "RevealDirectory expands an uncached ancestor and highlights the target" {
  let dispatch = test_dispatch()
  let model = test_model()
  let panel = { ..model.file_panel, open: true, session: "desktop-test" }
  let (_, next) = update(
    dispatch,
    FileEditor(RevealDirectory(Relative("src/foo"))),
    { ..model, file_panel: panel },
  )
  assert_true(next.file_panel.expanded.contains(Relative("src")))
  assert_true(next.file_panel.loading.contains(Relative("src")))
  assert_true(next.file_panel.highlighted is Some(Relative("src/foo")))
}

///|
test "RevealDirectory on an already-cached ancestor needs no reload" {
  let dispatch = test_dispatch()
  let model = test_model()
  let children : Map[@pathx.Relative, Array[@fileeditor.FileEntry]] = Map([
    (Relative("src"), []),
  ])
  let panel = {
    ..model.file_panel,
    open: true,
    session: "desktop-test",
    children,
  }
  let (_, next) = update(
    dispatch,
    FileEditor(RevealDirectory(Relative("src/foo"))),
    { ..model, file_panel: panel },
  )
  assert_true(next.file_panel.expanded.contains(Relative("src")))
  assert_false(next.file_panel.loading.contains(Relative("src")))
}

///|
test "HighlightCleared only clears a highlight that still matches" {
  let dispatch = test_dispatch()
  let model = test_model()
  // Rooted in the active session, or the post-dispatch `sync` re-roots the
  // panel and clears the highlight itself.
  let panel = {
    ..model.file_panel,
    session: "desktop-test",
    highlighted: Some(Relative("src")),
  }
  let (_, stale) = update(
    dispatch,
    FileEditor(HighlightCleared(Relative("old"))),
    { ..model, file_panel: panel },
  )
  assert_true(stale.file_panel.highlighted is Some(Relative("src")))
  let (_, cleared) = update(
    dispatch,
    FileEditor(HighlightCleared(Relative("src"))),
    { ..model, file_panel: panel },
  )
  assert_true(cleared.file_panel.highlighted is None)
}

///|
/// A prompt submitted mid-compaction must not start: the serve engine would
/// queue it behind the compaction, out of Stop's reach. The draft stays put.
test "a prompt submitted during compaction stays in the composer" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    compaction: Compacting,
    task: "do the thing",
  })
  let (_, next) = update(dispatch, Send, model)
  inspect(next.active().task, content="do the thing")
  inspect(next.active().messages.length(), content="0")
}

///|
/// A `/compact` sent mid-turn queues behind the open run in the engine. The
/// composer must say so immediately, swallow a duplicate, and keep the send
/// gate held through the gap between the turn's end and the engine's
/// compaction_started.
test "a mid-turn /compact stays visibly queued until compaction starts" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..running_conversation(),
    last_run_id: Some("r7"),
  })
  let (_, queued) = run_slash_command(dispatch, model, "compact")
  assert_true(queued.active().compaction is Queued)
  // One compaction at a time: the repeat is swallowed, not re-sent.
  let (_, again) = run_slash_command(dispatch, queued, "compact")
  assert_true(again.active().compaction is Queued)
  // The turn ends before compaction_started arrives; a prompt sent into
  // that gap would queue behind the compaction, out of Stop's reach.
  let (_, ended) = update(
    dispatch,
    Finished(run_id="r7", status="completed", answer=None),
    again,
  )
  assert_true(ended.active().compaction is Queued)
  let drafted = ended.replace_conversation({
    ..ended.active(),
    task: "next prompt",
  })
  let (_, held) = update(dispatch, Send, drafted)
  inspect(held.active().task, content="next prompt")
  // The engine reaches the queued compaction: queued flips into compacting.
  let (_, started) = update(
    dispatch,
    Engine(Some("r7"), CompactionStarted, session=None),
    held,
  )
  assert_true(started.active().compaction is Compacting)
}

///|
/// An idle `/compact` has no engine acknowledgment yet — the host may still
/// be spawning a serve engine for it (a resumed conversation compacted
/// before its first prompt) — but the request must hold the send gate
/// immediately: a prompt sent into that window would be consumed and
/// rejected by the host instead of held in the composer.
test "an idle /compact holds the send gate until the engine confirms" {
  let dispatch = test_dispatch()
  let (_, requested) = run_slash_command(dispatch, test_model(), "compact")
  assert_true(requested.active().compaction is Requested)
  // A repeat while the request is in flight is swallowed, not re-sent.
  let (_, again) = run_slash_command(dispatch, requested, "compact")
  assert_true(again.active().compaction is Requested)
  // A draft sent during the spawn/write window stays in the composer.
  let drafted = again.replace_conversation({
    ..again.active(),
    task: "next prompt",
  })
  let (_, held) = update(dispatch, Send, drafted)
  inspect(held.active().task, content="next prompt")
  inspect(held.active().messages.length(), content="0")
  // The engine confirms; the session stamp routes it (no run id exists yet).
  let (_, started) = update(
    dispatch,
    Engine(None, CompactionStarted, session=Some("desktop-test")),
    held,
  )
  assert_true(started.active().compaction is Compacting)
}

///|
/// Rabbita purity: applying the automatic-checkpoint event twice to the same
/// input produces the same transcript and never mutates the manual compaction
/// lifecycle.
test "update is pure: automatic checkpoint appends a summary" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    streaming_response: "partial",
  })
  let (_, once) = update(
    dispatch,
    Engine(Some("r7"), AutoCompactionFinished("checkpoint recap"), session=None),
    model,
  )
  let (_, twice) = update(
    dispatch,
    Engine(Some("r7"), AutoCompactionFinished("checkpoint recap"), session=None),
    model,
  )
  inspect(model.active().overlay.length(), content="0")
  inspect(once.active().overlay.length(), content="1")
  inspect(twice.active().overlay.length(), content="1")
  guard once.active().overlay.last() is Some(once_item) &&
    twice.active().overlay.last() is Some(twice_item) else {
    fail("expected checkpoint summaries")
  }
  assert_true(once_item.kind is Summary && twice_item.kind is Summary)
  inspect(once_item.content, content="checkpoint recap")
  inspect(twice_item.content, content="checkpoint recap")
  inspect(once.active().streaming_response, content="partial")
  inspect(twice.active().streaming_response, content="partial")
  assert_true(
    once.active().compaction is NotCompacting &&
    twice.active().compaction is NotCompacting,
  )
}

///|
/// Rabbita purity: context-yield guidance is a deterministic model update.
/// The raw stream event clears partial streams but does not close the run;
/// the host's following Finished message owns that transition.
test "update is pure: context yield appends continuation guidance" {
  let dispatch = test_dispatch()
  let answer = "[context ceiling] continue in a new turn"
  let model = running_model().replace_conversation({
    ..running_conversation(),
    streaming_response: "partial",
    streaming_reasoning: "thinking",
  })
  let (_, once) = update(
    dispatch,
    Engine(Some("r7"), ContextYield(answer), session=None),
    model,
  )
  let (_, twice) = update(
    dispatch,
    Engine(Some("r7"), ContextYield(answer), session=None),
    model,
  )
  inspect(model.active().overlay.length(), content="0")
  inspect(once.active().overlay.length(), content="1")
  inspect(twice.active().overlay.length(), content="1")
  guard once.active().overlay.last() is Some(once_item) &&
    twice.active().overlay.last() is Some(twice_item) else {
    fail("expected context-yield guidance")
  }
  assert_true(
    once_item.kind is Assistant(false) && twice_item.kind is Assistant(false),
  )
  inspect(once_item.content, content="[context ceiling] continue in a new turn")
  inspect(
    twice_item.content,
    content="[context ceiling] continue in a new turn",
  )
  inspect(once.active().streaming_response, content="")
  inspect(twice.active().streaming_response, content="")
  inspect(once.active().streaming_reasoning, content="")
  inspect(twice.active().streaming_reasoning, content="")
  assert_true(once.active().is_running() && twice.active().is_running())
}

///|
/// The successful ceiling path is one automatic Summary, one continuation
/// notice, then a warning terminal that re-opens Send. It never enters the
/// manual compaction lifecycle.
test "context yield settles after its automatic checkpoint" {
  let dispatch = test_dispatch()
  let answer = "[context ceiling] continue in a new turn"
  let (_, checkpointed) = update(
    dispatch,
    Engine(Some("r7"), AutoCompactionFinished("checkpoint recap"), session=None),
    running_model(),
  )
  let (_, yielded) = update(
    dispatch,
    Engine(Some("r7"), ContextYield(answer), session=None),
    checkpointed,
  )
  assert_true(yielded.active().is_running())
  let (_, settled) = update(
    dispatch,
    Finished(run_id="r7", status="context_yield", answer=Some(answer)),
    yielded,
  )
  inspect(settled.active().overlay.length(), content="2")
  guard settled.active().overlay.get(0) is Some(summary) &&
    settled.active().overlay.get(1) is Some(guidance) else {
    fail("expected checkpoint and guidance")
  }
  assert_true(summary.kind is Summary)
  inspect(summary.content, content="checkpoint recap")
  assert_true(guidance.kind is Assistant(false))
  inspect(guidance.content, content="[context ceiling] continue in a new turn")
  assert_true(settled.active().compaction is NotCompacting)
  assert_false(settled.active().is_running())
  guard settled.display_status() is Finished(outcome) else {
    fail("expected a finished status")
  }
  assert_true(outcome is ContextYield)
  inspect(outcome.label(), content="Context limit reached")
  assert_true(settled.display_status().kind() is Warn)
}

///|
/// The compaction summary lands as its own Summary item — never a tool call
/// the transcript loop would fold into the preceding turn's activity card
/// (which would also swallow that turn's answer bubble into the fold).
test "compaction_finished appends a standalone summary item" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    compaction: Compacting,
    last_run_id: Some("r7"),
  })
  let (_, next) = update(
    dispatch,
    Engine(
      Some("r7"),
      CompactionFinished("earlier turns compacted"),
      session=None,
    ),
    model,
  )
  guard next.active().overlay.last() is Some(item) && item.kind is Summary else {
    fail("expected a summary item")
  }
  inspect(item.content, content="earlier turns compacted")
  assert_true(next.active().compaction is NotCompacting)
}

///|
/// A conversation resumed and compacted before its first prompt of this
/// app-lifetime has no run id anywhere — the spawned engine stamps run 0 and
/// the conversation's `last_run_id` is still `None` — so compaction events
/// must route by the session the host stamps on them.
test "compaction events route by session when no run id matches" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    last_run_id: None,
  })
  let (_, started) = update(
    dispatch,
    Engine(None, CompactionStarted, session=Some("desktop-test")),
    model,
  )
  assert_true(started.active().compaction is Compacting)
  let (_, next) = update(
    dispatch,
    Engine(
      None,
      CompactionFinished("earlier turns compacted"),
      session=Some("desktop-test"),
    ),
    started,
  )
  guard next.active().overlay.last() is Some(item) && item.kind is Summary else {
    fail("expected a summary item")
  }
  assert_true(next.active().compaction is NotCompacting)
}

///|
/// The host synthesizes compaction_failed when the engine dies with a
/// compaction still queued behind the dead turn; that terminal event must
/// settle the queued notice like any other compaction failure.
test "compaction_failed settles a still-queued compaction" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    compaction: Queued,
    last_run_id: Some("r7"),
  })
  let (_, next) = update(
    dispatch,
    Engine(Some("r7"), CompactionFailed("engine exited"), session=None),
    model,
  )
  assert_true(next.active().compaction is NotCompacting)
  inspect(next.active().overlay.length(), content="1")
}

///|
/// A rejected compact request (no engine, host error) never produces
/// compaction events, so the rejection itself clears the queued notice and
/// lands the error in the transcript.
test "CompactRejected clears the queued notice and reports the error" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    compaction: Queued,
  })
  let (_, next) = update(
    dispatch,
    CompactRejected(session="desktop-test", message="no engine"),
    model,
  )
  assert_true(next.active().compaction is NotCompacting)
  inspect(next.active().overlay.length(), content="1")
}

///|
test "a startup check surfaces an installable release as the Update button" {
  let dispatch = test_dispatch()
  let (_, model) = update(
    dispatch,
    UpdateCheckFinished(
      result=CheckFound(version="0.2.0", installable=true),
      explicit=false,
    ),
    test_model(),
  )
  assert_true(
    model.update_ux is UpdateAvailable(version="0.2.0", installable=true),
  )
  assert_eq(model.notifications.length(), 0)
}

///|
test "quiet startup outcomes leave no trace; explicit ones answer" {
  let dispatch = test_dispatch()
  for
    result in [
      CheckUpToDate,
      CheckUnreachable(reason="offline"),
      CheckMalformed(reason="not json"),
    ] {
    let (_, silent) = update(
      dispatch,
      UpdateCheckFinished(result~, explicit=false),
      test_model(),
    )
    assert_true(silent.update_ux is UpdateUnknown)
    assert_eq(silent.notifications.length(), 0)
  }
  let (_, ok) = update(
    dispatch,
    UpdateCheckFinished(result=CheckUpToDate, explicit=true),
    test_model(),
  )
  assert_true(ok.update_ux is UpToDate)
  let (_, offline) = update(
    dispatch,
    UpdateCheckFinished(
      result=CheckUnreachable(reason="offline"),
      explicit=true,
    ),
    test_model(),
  )
  assert_true(
    offline.update_ux is UpdateCheckFailed(..) &&
    offline.update_ux is UpdateCheckFailed(message~) &&
    message.contains("offline"),
  )
}

///|
test "a broken package entry is loud even when the app asked" {
  let dispatch = test_dispatch()
  let (_, model) = update(
    dispatch,
    UpdateCheckFinished(
      result=CheckBroken(version="0.2.0", reason="url is not https"),
      explicit=false,
    ),
    test_model(),
  )
  assert_eq(model.notifications.length(), 1)
  assert_true(model.notifications[0].message.contains("url is not https"))
  assert_true(model.update_ux is UpdateCheckFailed(..))
}

///|
test "clicking Update goes straight to download when nothing runs" {
  let dispatch = test_dispatch()
  let available = {
    ..test_model(),
    update_ux: UpdateAvailable(version="0.2.0", installable=true),
  }
  let (_, clicked) = update(dispatch, UpdateClicked, available)
  assert_true(clicked.update_ux is DownloadingUpdate(version="0.2.0"))
  // Downloaded hands off to apply and marks the restart.
  let (_, done) = update(dispatch, UpdateDownloaded, clicked)
  assert_true(done.update_ux is RestartingForUpdate(version="0.2.0"))
}

///|
test "clicking Update asks first while a conversation runs" {
  let dispatch = test_dispatch()
  let busy = {
    ..test_model().replace_conversation({ ..test_conversation(), run: Starting }),
    update_ux: UpdateAvailable(version="0.2.0", installable=true),
  }
  let (_, asked) = update(dispatch, UpdateClicked, busy)
  assert_true(asked.update_ux is ConfirmingRestart(version="0.2.0"))
  // Cancel restores the offer; confirm starts the download.
  let (_, kept) = update(dispatch, CancelUpdateRestart, asked)
  assert_true(
    kept.update_ux is UpdateAvailable(version="0.2.0", installable=true),
  )
  let (_, confirmed) = update(dispatch, ConfirmUpdateRestart, asked)
  assert_true(confirmed.update_ux is DownloadingUpdate(version="0.2.0"))
}

///|
test "a failed download says why and restores the offer" {
  let dispatch = test_dispatch()
  let downloading = {
    ..test_model(),
    update_ux: DownloadingUpdate(version="0.2.0"),
  }
  let (_, failed) = update(
    dispatch,
    UpdateFailed(message="digest mismatch"),
    downloading,
  )
  assert_eq(failed.notifications.length(), 1)
  assert_true(failed.notifications[0].message.contains("digest mismatch"))
  assert_true(
    failed.update_ux is UpdateAvailable(version="0.2.0", installable=true),
  )
}

///|
test "a stale check reply cannot clobber a download in flight" {
  let dispatch = test_dispatch()
  let downloading = {
    ..test_model(),
    update_ux: DownloadingUpdate(version="0.2.0"),
  }
  let (_, next) = update(
    dispatch,
    UpdateCheckFinished(result=CheckUpToDate, explicit=false),
    downloading,
  )
  assert_true(next.update_ux is DownloadingUpdate(version="0.2.0"))
}

///|
test "switching the update channel forgets the previous answer" {
  let dispatch = test_dispatch()
  let available = {
    ..test_model(),
    update_ux: UpdateAvailable(version="0.2.0", installable=true),
  }
  let (_, switched) = update(
    dispatch,
    UpdateChannelChanged("staging"),
    available,
  )
  assert_true(switched.update_channel is Staging)
  assert_true(switched.update_ux is UpdateUnknown)
}

///|
test "check_update replies decode by kind" {
  assert_true(
    decode_update_check("{\"kind\":\"up_to_date\"}") is Some(CheckUpToDate),
  )
  assert_true(
    decode_update_check(
      "{\"kind\":\"available\",\"version\":\"0.2.0\",\"installable\":true}",
    )
    is Some(CheckFound(version="0.2.0", installable=true)),
  )
  // The host always writes `installable` on an `available` reply; one
  // without it is malformed rather than "not installable".
  assert_true(
    decode_update_check("{\"kind\":\"available\",\"version\":\"0.2.0\"}")
    is None,
  )
  assert_true(
    decode_update_check("{\"kind\":\"unreachable\",\"reason\":\"offline\"}")
    is Some(CheckUnreachable(reason="offline")),
  )
  assert_true(
    decode_update_check("{\"kind\":\"malformed\",\"reason\":\"not json\"}")
    is Some(CheckMalformed(reason="not json")),
  )
  assert_true(
    decode_update_check(
      "{\"kind\":\"broken\",\"version\":\"0.2.0\",\"reason\":\"bad url\"}",
    )
    is Some(CheckBroken(version="0.2.0", reason="bad url")),
  )
  // Unknown kinds and structurally unusable replies are indecipherable.
  assert_true(decode_update_check("{\"kind\":\"available\"}") is None)
  assert_true(decode_update_check("{\"kind\":\"surprise\"}") is None)
  assert_true(decode_update_check("garbage") is None)
}

///|
test "send shows the prompt as overlay until its commit lands" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    task: "build the thing",
  })
  let (_, sent) = update(dispatch, Send, model)
  // No optimistic durable write: the prompt is display overlay only.
  inspect(sent.active().messages.length(), content="0")
  inspect(sent.active().overlay.length(), content="1")
  guard sent.active().overlay[0].kind is User else {
    fail("expected a user overlay")
  }
  inspect(sent.active().watermark, content="0")
  // The durable commit lands the real item and retires the overlay twin.
  let (_, committed) = update(
    dispatch,
    SessionCommitted(session="desktop-test", sequence=1, kind="user", payload={
      "content": Json::string("build the thing"),
    }),
    sent,
  )
  inspect(committed.active().messages.length(), content="1")
  guard committed.active().messages[0].kind is User else {
    fail("expected a user item")
  }
  inspect(committed.active().overlay.length(), content="0")
  inspect(committed.active().watermark, content="1")
}

///|
test "a replayed commit at or below the watermark is dropped" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    messages: [{ kind: User, content: "already there" }],
    watermark: 2,
  })
  let (_, next) = update(
    dispatch,
    SessionCommitted(session="desktop-test", sequence=2, kind="user", payload={
      "content": Json::string("already there"),
    }),
    model,
  )
  inspect(next.active().messages.length(), content="1")
  inspect(next.active().watermark, content="2")
}

///|
test "a commit past the frontier buffers and flips into a reload" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    watermark: 1,
  })
  let (_, next) = update(
    dispatch,
    SessionCommitted(session="desktop-test", sequence=5, kind="user", payload={
      "content": Json::string("from the future"),
    }),
    model,
  )
  // The gap means missed broadcasts; nothing is applied out of order.
  inspect(next.active().messages.length(), content="0")
  inspect(next.active().watermark, content="1")
  guard next.active().sync is Reloading(buffered~) else {
    fail("expected a reload in flight")
  }
  inspect(buffered.length(), content="1")
  inspect(buffered[0].sequence, content="5")
}

///|
test "commits buffer while a reload is in flight" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    sync: Reloading(buffered=[]),
  })
  let (_, next) = update(
    dispatch,
    SessionCommitted(session="desktop-test", sequence=3, kind="user", payload={
      "content": Json::string("mid-reload"),
    }),
    model,
  )
  inspect(next.active().messages.length(), content="0")
  guard next.active().sync is Reloading(buffered~) else {
    fail("expected the reload to stay in flight")
  }
  inspect(buffered.length(), content="1")
}

///|
test "a snapshot drains buffered commits in sequence order" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation()
    // Out of arrival order on purpose; the drain sorts by sequence.
    ,
    sync: Reloading(buffered=[
      {
        sequence: 4,
        kind: "user",
        payload: { "content": Json::string("four") },
      },
      {
        sequence: 3,
        kind: "user",
        payload: { "content": Json::string("three") },
      },
    ]),
  })
  let (_, next) = update(
    dispatch,
    SessionRefreshed(
      session="desktop-test",
      items=[
        { kind: User, content: "one" },
        { kind: Assistant(false), content: "two" },
      ],
      watermark=2,
    ),
    model,
  )
  inspect(next.active().messages.length(), content="4")
  inspect(next.active().messages[2].content, content="three")
  inspect(next.active().messages[3].content, content="four")
  inspect(next.active().watermark, content="4")
  assert_true(next.active().sync is Synced)
}

///|
test "a snapshot already containing the buffered commits drops them" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    sync: Reloading(buffered=[
      { sequence: 2, kind: "user", payload: { "content": Json::string("dup") } },
    ]),
  })
  let (_, next) = update(
    dispatch,
    SessionRefreshed(
      session="desktop-test",
      items=[{ kind: User, content: "one" }, { kind: User, content: "dup" }],
      watermark=2,
    ),
    model,
  )
  inspect(next.active().messages.length(), content="2")
  inspect(next.active().watermark, content="2")
  assert_true(next.active().sync is Synced)
}

///|
test "a snapshot with a still-gapped buffer keeps reloading" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    sync: Reloading(buffered=[
      { sequence: 9, kind: "user", payload: { "content": Json::string("far") } },
    ]),
  })
  let (_, next) = update(
    dispatch,
    SessionRefreshed(
      session="desktop-test",
      items=[{ kind: User, content: "one" }],
      watermark=2,
    ),
    model,
  )
  inspect(next.active().watermark, content="2")
  guard next.active().sync is Reloading(buffered~) else {
    fail("expected another reload for the remaining gap")
  }
  inspect(buffered.length(), content="1")
  inspect(buffered[0].sequence, content="9")
}

///|
test "a failed refresh drops back to synced and the next commit heals it" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    messages: [{ kind: User, content: "kept" }],
    watermark: 1,
    sync: Reloading(buffered=[
      { sequence: 3, kind: "user", payload: { "content": Json::string("x") } },
    ]),
  })
  let (_, failed) = update(
    dispatch,
    SessionRefreshFailed(session="desktop-test"),
    model,
  )
  assert_true(failed.active().sync is Synced)
  inspect(failed.active().messages.length(), content="1")
  // The next contiguous commit applies normally.
  let (_, healed) = update(
    dispatch,
    SessionCommitted(session="desktop-test", sequence=2, kind="user", payload={
      "content": Json::string("next"),
    }),
    failed,
  )
  inspect(healed.active().messages.length(), content="2")
  inspect(healed.active().watermark, content="2")
}

///|
test "an assistant commit retires its reasoning and answer overlays" {
  let dispatch = test_dispatch()
  let (_, thought) = update(
    dispatch,
    Engine(Some("r7"), ReasoningMessage("think"), session=None),
    running_model(),
  )
  let (_, answered) = update(
    dispatch,
    Engine(Some("r7"), AssistantMessage("answer"), session=None),
    thought,
  )
  inspect(answered.active().overlay.length(), content="2")
  let (_, committed) = update(
    dispatch,
    SessionCommitted(session="desktop-test", sequence=1, kind="assistant", payload={
      "content": Json::string("answer"),
      "reasoning_content": Json::string("think"),
    }),
    answered,
  )
  // One durable item projects as reasoning + answer; both overlays retire.
  inspect(committed.active().messages.length(), content="2")
  inspect(committed.active().overlay.length(), content="0")
  inspect(committed.active().watermark, content="1")
}

///|
test "a commit for an unknown session changes nothing" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    SessionCommitted(session="desktop-elsewhere", sequence=1, kind="user", payload={
      "content": Json::string("hi"),
    }),
    test_model(),
  )
  inspect(next.conversations.length(), content="1")
  inspect(next.active().messages.length(), content="0")
}
