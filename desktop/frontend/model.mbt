///|
const DefaultModel : String = "deepseek-v4-pro"

///|
const DefaultMaxSteps : String = "1000"

///|
/// Legacy localStorage keys from when the page stored the engine endpoint
/// settings itself. Those now live on the host (`settings.get`/`set`); the
/// keys remain only so the desktop window can migrate stored values up once
/// and every page can purge the leftover secrets.
const LegacyApiKeyStorageKey : String = "openseek.deepseek_api_key"

///|
const LegacyCustomApiKeyStorageKey : String = "openseek.custom_api_key"

///|
const LegacyApiProviderStorageKey : String = "openseek.api_provider"

///|
const LegacyCustomApiUrlStorageKey : String = "openseek.custom_api_url"

///|
const LegacyWslEnabledStorageKey : String = "openseek.wsl_enabled"

///|
const LegacyWslDistroStorageKey : String = "openseek.wsl_distro"

///|
const LegacyWslEngineStorageKey : String = "openseek.wsl_engine"

///|
const NotificationCornerStorageKey : String = "openseek.notification_corner"

///|
/// Where the editor panel's file tree docks (bottom panel / right sidebar).
const TreeLayoutStorageKey : String = "openseek.tree_layout"

///|
/// Which release stream updates come from; stores "staging" for the staging
/// server, anything else reads as production.
const UpdateChannelStorageKey : String = "openseek.update_channel"

///|
/// Which chat-completions endpoint the engine talks to. `Openseek` is the
/// zero-config default — the proxy does not validate API keys. `Deepseek` is
/// the official endpoint and needs the user's own key. `Custom` is any other
/// DeepSeek-compatible endpoint; whether it needs a key is the endpoint's
/// business, so the key is optional there. The setting (and its
/// credentials) live on the host; this mirror is what `settings.get`/`set`
/// replies and the `settings.changed` broadcast last reported.
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
/// Unknown stored values fall back to the default provider, so a downgrade
/// (or a corrupted store) degrades to the zero-config endpoint instead of
/// wedging the app.
fn ApiProvider::parse(value : String) -> ApiProvider {
  match value.trim().to_owned() {
    "deepseek" => Deepseek
    "custom" => Custom
    _ => Openseek
  }
}

///|
/// The compaction lifecycle of one conversation, mirroring the host's
/// `EnginePhase` design: one value instead of loose booleans, so a compact
/// request that is in flight but not yet acknowledged still has a
/// representation — every phase but `NotCompacting` holds the send gate and
/// shows a composer notice, and a request the model forgot to track cannot
/// exist. Settled by the engine's `compaction_*` events, or by
/// `CompactRejected` when the request never reached one.
priv enum CompactionPhase {
  // Nothing pending; the only phase that accepts a `/compact`.
  NotCompacting
  // Requested while idle: the op is on the wire and the host may still be
  // spawning a serve engine for it (a resumed conversation compacted before
  // its first prompt — seconds, not milliseconds). `compaction_started`
  // confirms it.
  Requested
  // Requested mid-turn: the engine queues it behind the open run, so this
  // holds the gate through the gap between the turn's end and the queued
  // compaction's start.
  Queued
  // The engine reported `compaction_started` and has not yet reported the
  // summary or a failure.
  Compacting
}

///|
/// The run lifecycle of one conversation, as a single value: the old
/// `running`/`active_run_id`/`status` trio encoded the same facts three ways
/// and let them drift ("running with no id yet" was Starting only by
/// convention; a status of Running with the flag down was expressible).
/// Every gate reads this one field, so a phase the model forgot to track
/// cannot exist.
priv enum RunPhase {
  // Between runs; `ended` remembers how the last one closed (`None` before
  // the first run of this app-lifetime).
  NoRun(ended~ : RunEnd?)
  // Send accepted: the start op is in flight and no run id exists yet.
  Starting
  // The host's `started` event opened run `run_id`.
  Open(run_id~ : String, stage~ : TurnStage)
}

///|
/// How far an open turn has progressed — one axis, like the old status
/// column: a Stop overwrites the step display with "Cancelling" and stays
/// there (steering a dying turn is refused, so a later step must not flip
/// the gate back open).
priv enum TurnStage {
  // `started` arrived, no step event yet.
  Opened
  // The engine's latest 1-based step counter (`None` from engines that do
  // not number their steps).
  AtStep(Int?)
  // A Stop was sent and the engine has not yet honored it.
  Cancelling
}

///|
/// How a finished run closed, kept for the topbar/sidebar after the run
/// phase returns to `NoRun`.
priv enum RunEnd {
  RunFailed
  RunErrored
  RunFinished(RunOutcome)
}

///|
/// One conversation's full client-side state. Each conversation maps to a
/// durable engine session and, while running, to its own `--serve` engine
/// process in the host — several conversations can run turns concurrently,
/// so everything a run touches lives here rather than on the model.
priv struct Conversation {
  // Durable engine session backing this conversation; consecutive runs share
  // it so the agent keeps context between prompts.
  session_id : String
  // The project directory this conversation is attached to, `None` for a
  // scratch conversation in the app-managed workspace. Sent with every start
  // so the engine runs in the project and stores the session inside it. Also
  // one of the two roots (`cwd` first) a legacy absolute chip path is
  // relativized against before a jump.
  workspace : @pathx.Absolute?
  // Composer draft, kept per conversation so switching away (and back)
  // neither loses the text nor sends it to the wrong session.
  task : String
  // Mention chips attached to the draft (`$` skills, `#` symbols), part of the
  // draft and so likewise per conversation. Expanded into the prompt on send,
  // then cleared with the text.
  mentions : Array[Mention]
  // Where this conversation's run stands; see `RunPhase`. Replaces the old
  // `running`/`active_run_id`/`status` trio, whose redundant encodings could
  // drift apart (running with no id was "starting" only by convention).
  run : RunPhase
  // The most recent run id this conversation has owned, kept after the run
  // finishes. Compaction is requested while the engine is idle, so its
  // engine events arrive stamped with this id once the run phase is already
  // back to `NoRun`; routing them needs the retained id.
  last_run_id : String?
  // Where this conversation's compaction stands; see `CompactionPhase`.
  compaction : CompactionPhase
  // A run finished while this conversation was off screen and the user has
  // not looked since: the sidebar's running pulse settles into a solid dot
  // (accent for success, warn otherwise) until the conversation is opened.
  unseen_finish : Bool
  usage_tokens : Int
  // The conversation's workspace directory as reported by the host's
  // `started` event — `None` until the first run reports it. Display
  // (topbar tooltip), the working directory for `open_path`/`launch_app`,
  // and the preferred root for relativizing a legacy absolute chip path;
  // the host derives it from the session id, so it is never sent back with
  // a start request.
  cwd : @pathx.Absolute?
  // The git branch checked out in the workspace, reported by the host's
  // `workspace_branch` op — display only (topbar chip). `None` until a probe
  // answers (or when it fails); `Some("")` when the workspace is not a
  // repository. Either way the chip hides. Refreshed when a run starts, a
  // stored session opens, and a run finishes.
  branch : String?
  watcher_status : String
  // Live text of the in-flight assistant turn, accumulated from
  // `assistant_delta` / `reasoning_delta` events and cleared once the engine
  // commits the full message (or the step/run ends). Empty means not streaming.
  streaming_response : String
  streaming_reasoning : String
  // Steering input sent to the running turn but not yet settled by the
  // engine: it echoes each steer back as `steer_applied` (folded into the
  // turn at a step boundary) or `steer_dropped` (raced the turn's end).
  // Shown as pending bubbles until then; leftovers are swept into dropped
  // notices when the run ends, so the text never vanishes silently.
  pending_steers : Array[String]
  // The durable transcript: exactly what `session.load` snapshots and
  // `session.event` commits said, nothing else. Copy-on-write.
  messages : Array[@transcript.TranscriptItem]
  // The highest durable sequence `messages` reflects: commits at or below it
  // are already applied, `watermark + 1` applies next, and anything later is
  // a gap — this client missed a broadcast — answered by a reload.
  watermark : Int
  // Where the durable transcript stands relative to the store; see
  // `TranscriptSync`.
  sync : TranscriptSync
  // Display-only items the durable record has not committed yet: the
  // just-sent prompt, a step's settled text, tool cards, steer echoes, and
  // client-local notices (a rejected start, a dropped steer). Rendered after
  // `messages`; each durable commit retires its overlay twin (matched by
  // kind FIFO — worst case a twin lingers until the next same-kind commit or
  // reload, a purely cosmetic miss). Copy-on-write.
  overlay : Array[@transcript.TranscriptItem]
}

///|
/// Whether the conversation's durable transcript is up to date with the
/// store, or a re-read is in flight. Commits that arrive mid-reload are
/// buffered — the snapshot they follow may or may not contain them, and the
/// watermark decides once it lands.
priv enum TranscriptSync {
  Synced
  Reloading(buffered~ : Array[BufferedCommit])
}

///|
priv struct BufferedCommit {
  sequence : Int
  kind : String
  payload : Map[String, Json]
}

///|
/// What the main area shows: the active conversation, the Skills page, or
/// the Settings page. Selecting a conversation (or rotating to a new one)
/// always returns to the chat. Settings also opens on its own while the
/// configured endpoint is unusable, since the composer would be dead weight.
priv enum Screen {
  Chat
  Skills
  Settings
}

///|
/// Which trigger opened the composer's completion menu: `/` lists built-in
/// commands that act on the conversation, `$` lists installed skills whose
/// name is inserted into the prompt, `#` lists workspace symbols (fetched from
/// the conversation's language server) whose reference is inserted.
priv enum CompletionKind {
  SlashCommands
  SkillMentions
  Symbols
}

///|
/// One row of the composer completion menu.
priv struct CompletionItem {
  // The primary label shown in the row (e.g. "/compact" or "$review-pr").
  label : String
  // A short description shown next to the label.
  detail : String
  // For a slash command, the id its accepted action dispatches on; empty for
  // skills. For a skill, `insert` carries the text dropped into the composer.
  command : String
  insert : String
  // A symbol row's resolved location — workspace-relative path and the
  // symbol's full range (one-based, viewer coordinates) — so the chip it
  // becomes can jump there and select the named code. `None` for slash
  // commands, skills, and symbols the language server could not place in a
  // file. A server that placed the symbol without a range yields an empty
  // range anchored at its line.
  path : String?
  range : @common.Range?
}

///|
/// One accepted mention, shown as a chip above the composer and folded into
/// the outgoing prompt's `<user_mentions>` envelope on send. `ref` is the
/// envelope form itself (`$` skill, `#` symbol, or an editor comment) — the
/// single source for the chip's glyph/label/jump target (`mention_chip`) and
/// for dedup. `range` keeps the full resolved range the envelope's
/// `file:line` cannot carry, so a draft chip's jump still selects the exact
/// span (`None` for a skill or an unplaced symbol).
priv struct Mention {
  ref_ : @mention_context.MentionRef
  range : @common.Range?
}

///|
/// The composer's open completion menu: the trigger that opened it, the
/// currently matching rows, and which row is highlighted. Absent when the
/// composer text does not begin with a live trigger. `loading` is set only for
/// a `#` menu whose results for the current query have not arrived yet, so the
/// empty menu can say "Searching…" rather than "No symbols".
priv struct Completion {
  kind : CompletionKind
  items : Array[CompletionItem]
  selected : Int
  loading : Bool
}

///|
/// The last workspace-symbol results, cached so the `#` menu can show them
/// without refetching while the query is unchanged. `session` records which
/// conversation they belong to, so switching conversations refetches rather
/// than showing another workspace's symbols; `query` is the trigger text they
/// answer, the key that decides whether a keystroke needs a fresh fetch.
priv struct SymbolCache {
  session : String
  query : String
  items : Array[CompletionItem]
}

///|
fn empty_symbol_cache() -> SymbolCache {
  { session: "", query: "", items: [] }
}

///|
/// The mooncakes.io skill catalog as the Skills page sees it. One enum, so
/// "loading", "loaded empty" and "failed" cannot be conflated.
priv enum SkillsCatalog {
  CatalogIdle
  CatalogLoading
  CatalogReady(Array[@transcript.MarketSkillItem])
  CatalogFailed(String)
}

///|
/// Whether the host bridge is up — three states the old `bridge_ready` bool
/// plus "why not" string encoded with an empty-string sentinel: still
/// probing for the injected bridge, connected, or given up with a reason.
priv enum BridgeState {
  Connecting
  Connected
  BridgeLost(String)
}

///|
priv struct Model {
  // Whether the host bridge is up; see `BridgeState`.
  bridge : BridgeState
  selected_model : String
  max_steps : String
  // Whether the host has a key stored for each keyed provider. The key text
  // itself never reaches a client — the Settings page only needs presence
  // (placeholder wording, the ready gate); a new key is staged in
  // `setup_api_key` until saved through `settings.set`.
  deepseek_key_saved : Bool
  custom_key_saved : Bool
  setup_api_key : String
  // Which endpoint the engine talks to; `custom_api_url` only matters when
  // the provider is `Custom`. Both mirror the host's settings store and are
  // edited through `settings.set`.
  api_provider : ApiProvider
  custom_api_url : String
  // Host-settings writes still in flight. While any are, incoming
  // `settings.changed` broadcasts and `settings.get` replies are stale by
  // construction (they may predate the pending write) and are dropped; the
  // last write's own reply reconciles the mirror.
  settings_saves : Int
  // A legacy localStorage migration's push is in flight; its success is
  // what deletes the migrated secrets from localStorage.
  legacy_cleanup_pending : Bool
  // Run the serve engine inside WSL instead of natively. Windows-host-only:
  // `host_wsl` (the host's own capability, from `host.meta` at bridge time —
  // the page may run on any device while the engine runs on the host) gates
  // both the settings section and what `start` sends. `wsl_distro` empty
  // means the user's default distro; `wsl_engine` empty means `openseek` on
  // the distro's PATH. The three settings persist to localStorage as they
  // change.
  host_wsl : Bool
  // Whether this page is the desktop window (the proton webview) rather than
  // a browser reached through a relay. Probed once at startup. Gates the
  // self-update flow: applying an update swaps the
  // bundle under the desktop process and relaunches through the window's
  // close path — from a browser tab, `window.close()` exits nothing, and the
  // update would yank the app out from under whoever is at the machine.
  is_desktop : Bool
  wsl_enabled : Bool
  wsl_distro : String
  wsl_engine : String
  // Whether the host prefers a dark color scheme. The app's own palette
  // follows `prefers-color-scheme` in CSS; this mirror drives the embedded
  // viewer's `data-theme` attribute, which CSS media queries cannot set.
  // Seeded at startup and kept fresh by `watch_color_scheme`.
  dark_mode : Bool
  // Whether the left sidebar (chat list + navigation) is shown. Collapsing it
  // hands the full width to the conversation; the topbar toggle brings it back.
  sidebar_open : Bool
  // Whether the sidebar's "Chats" section (the default store's loose
  // conversations) is folded down to its heading; clicking the heading flips
  // it.
  chats_collapsed : Bool
  // Whether the sidebar's "Workspaces" section (the attached projects and their
  // nested conversations) is folded down to its heading; clicking the heading
  // flips it.
  workspaces_collapsed : Bool
  // The conversation on screen; always present in `conversations` once the
  // startup session rotation lands.
  active_session : String
  // Durable session currently being fetched from the host, if any. Sidebar
  // selections can race; only the latest request may activate a stored session.
  loading_session : String
  // Every conversation with live client state this app run: the active one,
  // those still running in the background, and those visited and kept for an
  // instant switch back. Copy-on-write, like the transcript arrays.
  conversations : Array[Conversation]
  // Durable sessions known to the engine's store, newest first, refreshed
  // when the bridge connects and when a run reaches the store. A new
  // conversation appears here once its first turn has been persisted.
  sessions : Array[@transcript.SessionListItem]
  // Conversations the host has archived (durable record moved into the
  // store's `archived` twin); the sidebar tucks their rows under a collapsed
  // "Archived" group with an unarchive control. Reported by the host in the
  // same entry shape as the live list.
  archived : Array[@transcript.SessionListItem]
  // Project directories attached as workspaces: the host registry's absolute
  // paths in registration order. The sidebar shows one section per entry.
  workspaces : Array[String]
  // Where "New chat" lands: a registered workspace path, or "" for the
  // default scratch store. Follows the conversation last opened or created.
  active_workspace : String
  // The in-app folder picker behind "Add a workspace"; None while closed.
  workspace_picker : WorkspacePicker?
  // Whether the transcript is scrolled to its bottom. Streaming output only
  // auto-follows while this holds — scrolling up to read history must not be
  // yanked back down by the next delta. Maintained by a DOM scroll watcher;
  // explicit user actions (sending, switching conversations) re-pin it.
  transcript_pinned : Bool
  // The Skills page: the registry catalog, the local library's contents,
  // the search filter, entries with an install/uninstall in flight (keyed
  // by the catalog entry's source label or the installed entry's id), and
  // the last failure to show. The catalog is fetched when the page opens
  // and kept for the app run; the installed list refreshes on open and
  // after every successful action.
  screen : Screen
  skills_catalog : SkillsCatalog
  installed_skills : Array[@transcript.InstalledSkillItem]
  skills_query : String
  skills_busy : Array[String]
  skills_notice : String
  // The composer completion menu, open only while the active conversation's
  // draft begins with a `/` or `$` trigger. Lives on the model rather than the
  // conversation: it is transient UI for the on-screen composer, recomputed on
  // every keystroke and dismissed on blur, send, or conversation switch.
  completion : Completion?
  // The last `#` symbol search's results, kept so the menu shows instantly
  // while the query is unchanged. Recomputed on every keystroke and refetched
  // when the query or conversation changes.
  symbol_cache : SymbolCache
  // The topbar app launcher. The app list is probed by the host once (the
  // first time the menu opens) and kept for the app run.
  launcher : Launcher
  // The editor side-panel: the active conversation's file tree and the file
  // shown in the embedded viewer. Rooted at `active().cwd`; rebuilt when the
  // active conversation changes. Owned by the `fileeditor` package; this
  // model only carries its state and routes `FileEditor` messages to it.
  file_panel : @fileeditor.State
  // Transient error toasts, oldest first, and the id the next toast will
  // take. Ids only ever grow, so a toast's auto-dismiss timer can never
  // collide with a later toast.
  notifications : Array[Notification]
  notification_seq : Int
  // Which window corner toasts pop up in; a Settings choice, persisted.
  notification_corner : NotificationCorner
  // Where the editor panel's file tree docks; a Settings choice, persisted.
  tree_layout : @fileeditor.TreeLayout
  // Which release stream `check_update` asks; a Settings choice, persisted.
  update_channel : UpdateChannel
  // Where the self-update flow stands, from "never checked" through the
  // download to the restart. One enum, so "checking", "downloading" and
  // "confirming" cannot overlap.
  update_ux : UpdateUx
}

///|
/// The topbar app launcher's state: whether its menu is open, the detected
/// apps as a fetch lifecycle (the old `loaded` flag plus error-string
/// sentinel let "loaded with an error" and "failed but loaded" be written).
priv struct Launcher {
  open : Bool
  apps : LauncherApps
}

///|
/// The in-app folder picker's state: the host directory currently shown,
/// its parent (None at the filesystem root), its subdirectories, and the
/// editable path field. `loading` marks a browse in flight; `error` keeps a
/// failed navigation's message beside the previous listing, which stays
/// usable. `generation` numbers the latest browse request — against a
/// remote gateway replies can finish out of order, and only the newest
/// one's reply may land, or a slow older listing would move the picker
/// back and Confirm would register the wrong directory.
priv struct WorkspacePicker {
  path : String
  entries : Array[String]
  input : String
  loading : Bool
  error : String?
  generation : Int
}

///|

///|
/// A picker that just opened: nothing browsed yet, first listing (the home
/// directory) on its way.
fn opening_workspace_picker() -> WorkspacePicker {
  {
    path: "",
    entries: [],
    input: "",
    loading: true,
    error: None,
    generation: 1,
  }
}

///|
/// The launcher's probe of the host's installed apps. There is no separate
/// "fetching" state: a fetch is triggered by opening the menu, and until the
/// reply lands the menu renders `AppsNotFetched` as "Finding apps…" (or
/// keeps the previous failure on a retry, exactly as before).
priv enum LauncherApps {
  AppsNotFetched
  AppsFetched(Array[@transcript.LauncherAppItem])
  AppsFailed(String)
}

///|
/// One `settings.get`/`settings.set` reply (or `settings.changed`
/// broadcast), decoded: the host's engine endpoint settings, with key
/// material reduced to presence.
priv struct HostSettings {
  provider : String
  custom_api_url : String
  has_deepseek_key : Bool
  has_custom_key : Bool
  wsl_enabled : Bool
  wsl_distro : String
  wsl_engine : String
}

///|
priv enum Msg {
  Init
  BridgeReady
  BridgeUnavailable(String)
  // The host's `host.meta` reply: whether the host itself can run the engine
  // inside WSL (a Windows host). The page's own platform says nothing — a
  // phone browser may drive a Windows host and a Windows browser a Mac one.
  HostMetaLoaded(wsl~ : Bool)
  // UI preferences read back from localStorage at startup. Engine endpoint
  // settings are the host's (`HostSettingsLoaded`); only page-local looks
  // live here.
  SettingsLoaded(
    notification_corner~ : String,
    tree_layout~ : String,
    update_channel~ : String
  )
  // The host's settings, from a `settings.get` reply or a peer client's
  // edit broadcast as `settings.changed`. Applied only while no local write
  // is in flight — see `Model::settings_saves`.
  HostSettingsLoaded(HostSettings)
  // A `settings.set` this client sent came back with the post-write state.
  HostSettingsApplied(HostSettings)
  // A `settings.set` this client sent failed; the message pops as a toast.
  HostSettingsSaveFailed(String)
  // The legacy localStorage engine settings, read at bridge time. The
  // desktop window migrates them up to the host once; a browser page only
  // purges them (a stale secret in shared storage is the leak this design
  // removes).
  LegacySettingsRead(
    provider~ : String,
    custom_url~ : String,
    api_key~ : String,
    custom_api_key~ : String,
    wsl_enabled~ : String,
    wsl_distro~ : String,
    wsl_engine~ : String
  )
  TaskChanged(String)
  // Move the completion menu's highlight by a delta (−1 up, +1 down), wrapping
  // at the ends. Ignored when the menu is closed.
  CompletionMove(Int)
  // Accept the highlighted completion: run the slash command or insert the
  // skill mention into the composer.
  CompletionAccept
  // Accept a specific completion row by index, for a mouse click on the menu.
  CompletionPick(Int)
  // Close the completion menu without acting (Escape, or a click away).
  CompletionDismiss
  // Remove a mention chip from the active conversation's draft, by index.
  RemoveMention(Int)
  // Jump the editor side-panel to a mention chip's resolved location, by
  // index. A no-op for a chip with no `path` (a skill, or an unresolved
  // symbol).
  JumpToMention(Int)
  // Jump the editor side-panel to a transcript chip's resolved location — a
  // sent message's mention, parsed back out of its `<user_mentions>` envelope,
  // so it carries the location itself rather than a draft index. The path is
  // the envelope's raw text: workspace-relative for chips minted since the
  // panel started recording relative names, possibly absolute in a legacy
  // envelope — `open_editor_at` classifies and relativizes. `range` is the
  // chip's line span (the envelope stores no columns); an annotation chip
  // also carries its comment text, re-shown as an editor bubble over that
  // range.
  JumpToLocation(path~ : String, range~ : @common.Range?, annotation~ : String?)
  // A `workspace_symbols` reply: `session`/`query` say which request it answers
  // so a reply that lost a conversation switch or a later keystroke is dropped.
  SymbolsLoaded(
    session~ : String,
    query~ : String,
    items~ : Array[CompletionItem]
  )
  // A failed search reads as "no symbols", so it carries no message to show —
  // only the `session`/`query` needed to settle the right menu.
  SymbolsFailed(session~ : String, query~ : String)
  ModelChanged(String)
  MaxStepsChanged(String)
  SetupApiKeyChanged(String)
  ProviderChanged(String)
  CustomApiUrlChanged(String)
  // The engine-environment select ("native"/"wsl") and the WSL text fields.
  WslModeChanged(String)
  WslDistroChanged(String)
  WslEngineChanged(String)
  // The Settings choice of which window corner error toasts pop up in.
  NotificationCornerChanged(String)
  // The Settings choice of where the editor's file tree docks.
  TreeLayoutChanged(String)
  // A toast's lifetime elapsed; drops it unless a click already did.
  NotificationExpired(Int)
  // A toast was clicked: dismiss it now.
  DismissNotification(Int)
  // The Settings choice of release stream (production/staging, by wire name).
  UpdateChannelChanged(String)
  // The Settings "Check for updates" button.
  CheckForUpdates
  // A `check_update` reply (or its failure, folded into `Unreachable`).
  // `explicit` says a user asked, which is what decides how loudly each
  // outcome shows.
  UpdateCheckFinished(result~ : UpdateCheck, explicit~ : Bool)
  // The accent Update button (sidebar or Settings row): confirm first when
  // a conversation is running, otherwise start the download.
  UpdateClicked
  // The interrupt-confirmation modal's two exits.
  ConfirmUpdateRestart
  CancelUpdateRestart
  // `download_update` finished: the bundle is staged and verified.
  UpdateDownloaded
  // The download or the swap failed; back to Available with a toast.
  UpdateFailed(message~ : String)
  // The host swapped the bundle; close the window so `main` can relaunch.
  UpdateApplied
  OpenSetup
  ToggleSidebar
  // The sidebar's "Chats" heading was clicked — fold or unfold the section.
  ToggleChatsSection
  // The sidebar's "Workspaces" heading was clicked — fold or unfold the section.
  ToggleWorkspacesSection
  SaveApiKey
  OpenSkills
  SkillsQueryChanged(String)
  SkillsCatalogLoaded(Array[@transcript.MarketSkillItem])
  SkillsCatalogFailed(String)
  InstalledSkillsLoaded(Array[@transcript.InstalledSkillItem])
  // A failure outside install/uninstall (the installed-list refresh).
  SkillsNotice(String)
  InstallSkill(@transcript.MarketSkillItem)
  // Uninstall by library entry id; only registry installs get the button.
  UninstallSkill(String)
  // An install/uninstall settled: `key` is the busy entry to release, and a
  // non-empty `error` becomes the panel's notice (success refreshes the
  // installed list instead).
  SkillActionDone(key~ : String, error~ : String)
  Send
  // The host reported a steer that never reached the engine (turn already
  // closed, engine dead, or the bridge call itself failed): carries the
  // session and original text so the right conversation's pending
  // acknowledgment can settle.
  SteerUndelivered(session~ : String, text~ : String)
  Stop
  NewChat
  SessionRotated(String)
  SessionsLoaded(Array[@transcript.SessionListItem])
  SessionsFailed(String)
  // The host's `session.changed` broadcast: another client archived or
  // unarchived a conversation, so both sidebar lists must be re-read.
  SessionsChanged
  OpenSession(String)
  // The user clicked the system notification a finished run posted: jump to
  // the conversation that owned that run (the window itself is already
  // brought forward natively).
  NotificationClicked(run_id~ : String)
  SessionLoaded(
    session~ : String,
    items~ : Array[@transcript.TranscriptItem],
    watermark~ : Int
  )
  // Loading a stored session failed before its conversation ever existed
  // (bridge call errored, or the data was malformed): pops an error toast
  // rather than poisoning the conversation on screen. `session` says which
  // request failed, so a load abandoned by a newer selection is dropped.
  SessionLoadFailed(session~ : String, message~ : String)
  // A background re-read of a conversation's durable record (a commit-gap
  // resync, or a reload for a foreign run): same data as `SessionLoaded`,
  // but it never activates the conversation or steals the screen.
  SessionRefreshed(
    session~ : String,
    items~ : Array[@transcript.TranscriptItem],
    watermark~ : Int
  )
  // A background re-read failed. The conversation drops back to `Synced`
  // (with its buffered commits discarded) — the next commit's gap check
  // retries the reload, so a transient read failure heals itself.
  SessionRefreshFailed(session~ : String)
  // The host's `session.event` broadcast: one durably committed store event.
  // Together with `session.load` snapshots these are the transcript's only
  // durable sources; the live `agent.event` stream is display overlay.
  SessionCommitted(
    session~ : String,
    sequence~ : Int,
    kind~ : String,
    payload~ : Map[String, Json]
  )
  // A host-side action with no conversation of its own (opening a file in
  // the system app, launching an app) failed: pops an error toast.
  HostActionFailed(String)
  // The registered workspaces — the reply to `list_workspaces` and to a
  // successful add/remove alike.
  WorkspacesLoaded(Array[String])
  // Open the in-app folder picker (browsing starts at the host's home
  // directory). The picker renders host-side listings, so it works the
  // same against the embedded gateway and a remote one.
  PickWorkspace
  // Browse into a directory: a subdirectory row, the parent, or the typed
  // path field on Enter.
  WorkspacePickerNavigate(String)
  // One directory's listing came back from the host; `generation` names
  // the browse request it answers, so a stale reply is dropped.
  WorkspacePickerLoaded(
    path~ : String,
    entries~ : Array[String],
    generation~ : Int
  )
  // A navigation failed; the message shows in the picker and the previous
  // listing stays usable.
  WorkspacePickerFailed(message~ : String, generation~ : Int)
  // The picker's path field changed.
  WorkspacePickerInput(String)
  // Register the picker's current directory and close it.
  WorkspacePickerConfirm
  WorkspacePickerClose
  // Detach a workspace: only the registry entry goes away — the directory
  // and the sessions inside it stay, so re-adding restores them.
  RemoveWorkspace(String)
  WorkspaceFailed(String)
  // Start a fresh conversation in a workspace ("" = the default store).
  NewChatIn(String)
  // Archive a conversation: the host moves its durable record into the
  // store's `archived` twin and the sidebar moves the row under the Archived
  // group.
  ArchiveSession(String)
  // Restore an archived conversation into the live list.
  UnarchiveSession(String)
  // The archived conversations — the reply to `archived_sessions` and to a
  // successful `archive_session`/`unarchive_session` alike.
  ArchivedLoaded(Array[@transcript.SessionListItem])
  ArchiveFailed(String)
  // The transcript's at-bottom state changed (the user scrolled away from,
  // or back to, the tail). Reported by the DOM scroll watcher.
  TranscriptPinned(Bool)
  // The floating "jump to latest" button: scroll the transcript back to its
  // tail and re-pin auto-follow.
  JumpToLatest
  // The host's dark-mode preference changed (the user switched the OS theme).
  // Reported by the `matchMedia` watcher.
  ColorSchemeChanged(Bool)
  // A `workspace_branch` reply: the git branch of `session`'s workspace —
  // `Some("")` when it is not a repository, `None` when the probe failed or
  // answered unintelligibly.
  BranchLoaded(session~ : String, branch~ : String?)
  // A file path in the transcript was clicked: open it in the system's
  // default app. The host resolves the path inside the active conversation's
  // workspace.
  OpenFile(String)
  // Open or close the topbar app launcher; opening it fetches the installed-app
  // list the first time.
  ToggleLauncher
  LauncherLoaded(Array[@transcript.LauncherAppItem])
  LauncherFailed(String)
  // Launch one detected app (by its id) on the active conversation's workspace.
  LaunchApp(String)
  // The host accepted a prompt: `session` routes the event to its
  // conversation, and everything after a `started` routes by `run_id`.
  // `task` is the prompt text — a client that did not send it (another
  // window, a mid-run join) has no other live source for the prompt bubble.
  Started(
    run_id~ : String,
    session~ : String,
    model~ : String,
    max_steps~ : Int,
    cwd~ : @pathx.Absolute?,
    task~ : String?
  )
  // The complete in-flight run set, from an `agent.runs` resync. Any
  // conversation still showing an open run this set lacks ended while the
  // client was away — its terminal event is gone for good (reconnect =
  // resync; transients are not replayed), so this is what closes it.
  RunsSettled(live~ : Array[String])
  // A stream event from an engine. The run id is `None` for events emitted
  // before any run of the engine process's lifetime. `session` is the
  // conversation the host stamped on it (`None` when the payload carries no
  // stamp): idle events (the compaction lifecycle, background notices) route
  // by it, because a conversation compacted before its first prompt of this
  // app-lifetime has no run id to match.
  Engine(String?, @transcript.EngineEvent, session~ : String?)
  // The editor side-panel's own messages (tree, viewer, diagnostics,
  // comments), routed to the `fileeditor` package's update. The one
  // exception is `EditorCommentAdded`, which this update intercepts: the
  // comment becomes a chip on the composer draft, which only the app model
  // knows about.
  FileEditor(@fileeditor.Msg)
  // The start request for that conversation never produced a run (the bridge
  // call failed or the host refused it).
  Failed(session~ : String, message~ : String)
  // A host error without a run (`run_id` is `None` — a pre-run failure)
  // belongs to whatever conversation the user is looking at; `diagnostics`
  // is stderr worth appending, when the host captured any.
  Error(run_id~ : String?, message~ : String, diagnostics~ : String?)
  // The `compact` bridge request itself was rejected (no engine, host error):
  // nothing will report compaction events, so the conversation's queued /
  // in-flight compaction notice must be cleared here, not by the stream.
  CompactRejected(session~ : String, message~ : String)
  // `answer` accompanies normal success and context yield (where it is
  // continuation guidance); other terminal statuses carry none.
  Finished(run_id~ : String, status~ : String, answer~ : String?)
}

///|
/// A workspace registry token ("" = the default store) as a typed root. The
/// tokens come from the host's registry and store replies, so a non-empty one
/// is known-absolute — this is the one place that provenance is collapsed
/// into the type.
fn workspace_root(token : String) -> @pathx.Absolute? {
  if token.is_empty() {
    None
  } else {
    Some(Absolute(token))
  }
}

///|
/// A conversation's workspace back in registry-token form ("" = the default
/// store), for sidebar grouping and store-addressed ops.
fn workspace_token(root : @pathx.Absolute?) -> String {
  if root is Some(root) {
    root.0
  } else {
    ""
  }
}

///|
fn empty_conversation(
  session_id : String,
  workspace? : String = "",
) -> Conversation {
  {
    session_id,
    workspace: workspace_root(workspace),
    task: "",
    mentions: [],
    run: NoRun(ended=None),
    last_run_id: None,
    compaction: NotCompacting,
    unseen_finish: false,
    usage_tokens: 0,
    cwd: None,
    branch: None,
    watcher_status: "",
    streaming_response: "",
    streaming_reasoning: "",
    pending_steers: [],
    messages: [],
    watermark: 0,
    sync: Synced,
    overlay: [],
  }
}

///|
fn initial_model() -> Model {
  {
    bridge: Connecting,
    selected_model: DefaultModel,
    max_steps: DefaultMaxSteps,
    deepseek_key_saved: false,
    custom_key_saved: false,
    setup_api_key: "",
    api_provider: Openseek,
    custom_api_url: "",
    settings_saves: 0,
    legacy_cleanup_pending: false,
    host_wsl: false,
    is_desktop: @interop.using_proton_bridge(),
    wsl_enabled: false,
    wsl_distro: "",
    wsl_engine: "",
    dark_mode: host_prefers_dark(),
    sidebar_open: true,
    chats_collapsed: false,
    workspaces_collapsed: false,
    active_session: "",
    loading_session: "",
    conversations: [],
    sessions: [],
    archived: [],
    workspaces: [],
    active_workspace: "",
    workspace_picker: None,
    transcript_pinned: true,
    screen: Chat,
    skills_catalog: CatalogIdle,
    installed_skills: [],
    skills_query: "",
    skills_busy: [],
    skills_notice: "",
    completion: None,
    symbol_cache: empty_symbol_cache(),
    launcher: { open: false, apps: AppsNotFetched },
    file_panel: @fileeditor.State::empty(),
    notifications: [],
    notification_seq: 0,
    notification_corner: BottomRight,
    tree_layout: RightSidebar,
    update_channel: Production,
    update_ux: UpdateUnknown,
  }
}

///|
/// Whether a catalog entry (identified by its source label) is already in
/// the local library — at that exact version; an older install keeps the
/// Install button alive as the upgrade path.
fn Model::skill_installed(self : Model, source : String) -> Bool {
  for skill in self.installed_skills {
    if skill.source == source {
      return true
    }
  }
  false
}

///|
/// Fold one host settings payload into the mirror. The default provider
/// needs no setup, so the Settings page only takes over when the settings
/// are incomplete (official endpoint without a key, custom endpoint without
/// a URL); it never navigates away on its own.
fn Model::apply_host_settings(self : Model, settings : HostSettings) -> Model {
  let next = {
    ..self,
    api_provider: ApiProvider::parse(settings.provider),
    custom_api_url: settings.custom_api_url,
    deepseek_key_saved: settings.has_deepseek_key,
    custom_key_saved: settings.has_custom_key,
    wsl_enabled: settings.wsl_enabled,
    wsl_distro: settings.wsl_distro,
    wsl_engine: settings.wsl_engine,
  }
  { ..next, screen: if next.api_ready() { next.screen } else { Settings } }
}

///|
/// Whether the configured endpoint is usable as it stands: the default
/// OpenSeek proxy always is, the official endpoint needs a key stored on
/// the host, and a custom endpoint needs at least a URL. The credentials
/// themselves live on the host; a start carries none.
fn Model::api_ready(self : Model) -> Bool {
  match self.api_provider {
    Openseek => true
    Deepseek => self.deepseek_key_saved
    Custom => !self.custom_api_url.trim().is_empty()
  }
}

///|
/// The status implied by the settings alone: whether the configured endpoint
/// is ready to accept a prompt, and what is missing when it is not.
fn Model::settings_status(self : Model) -> Status {
  if self.api_ready() {
    Ready
  } else if self.api_provider is Deepseek {
    ApiKeyRequired
  } else {
    SetupRequired
  }
}

///|
/// The status the top bar shows: bridge problems first, then the active
/// conversation's own run state, and — only when that conversation is idle —
/// the settings-derived readiness. Purely derived, so update handlers never
/// have to keep a stored status in sync with settings changes.
fn Model::display_status(self : Model) -> Status {
  match self.bridge {
    Connecting => WaitingBridge
    BridgeLost(message) => Unavailable(message)
    Connected =>
      match self.active().run {
        NoRun(ended=None) => self.settings_status()
        NoRun(ended=Some(RunFailed)) => Failed
        NoRun(ended=Some(RunErrored)) => Errored
        NoRun(ended=Some(RunFinished(outcome))) => Finished(outcome)
        Starting => Starting
        Open(stage=Opened, ..) => Running
        Open(stage=AtStep(step), ..) => Step(step)
        Open(stage=Cancelling, ..) => Cancelling
      }
  }
}

///|
fn Model::find_conversation(self : Model, session_id : String) -> Conversation? {
  for conv in self.conversations {
    if conv.session_id == session_id {
      return Some(conv)
    }
  }
  None
}

///|
/// The workspace a session belongs to: the sidebar list's grouping when the
/// store knows the session, the live conversation's own placement otherwise
/// (a fresh chat that has not reached the store yet). "" = the default store.
fn Model::session_workspace(self : Model, session_id : String) -> String {
  for item in self.sessions {
    if item.id == session_id {
      return item.workspace
    }
  }
  match self.find_conversation(session_id) {
    Some(conv) => workspace_token(conv.workspace)
    None => ""
  }
}

///|
/// The conversation on screen. Until the startup session rotation lands the
/// model has no conversations yet; an empty placeholder keeps the view (and
/// every handler reading the active conversation) total.
fn Model::active(self : Model) -> Conversation {
  if self.find_conversation(self.active_session) is Some(conv) {
    conv
  } else {
    empty_conversation(self.active_session)
  }
}

///|
/// Whether the conversation on screen is a fresh "New chat" — nothing sent
/// yet and no stored record, so it owns no sidebar row of its own. While this
/// holds, the active workspace's row carries the sidebar's selection
/// highlight in its place.
fn Model::composing_new_chat(self : Model) -> Bool {
  let conv = self.active()
  if conv.has_begun() {
    return false
  }
  for item in self.sessions {
    if item.id == conv.session_id {
      return false
    }
  }
  true
}

///|
/// Replace (or add) the entry sharing `conv`'s session id, copy-on-write —
/// prior model snapshots keep their own conversations array.
fn Model::replace_conversation(self : Model, conv : Conversation) -> Model {
  let conversations = self.conversations.copy()
  for index, existing in conversations {
    if existing.session_id == conv.session_id {
      conversations[index] = conv
      return { ..self, conversations, }
    }
  }
  conversations.push(conv)
  { ..self, conversations, }
}

///|
/// The conversation that owns run `run_id`. Engine events route by run id,
/// so a backgrounded conversation keeps receiving its own stream.
fn Model::conversation_by_run(self : Model, run_id : String) -> Conversation? {
  for conv in self.conversations {
    if conv.run is Open(run_id=active, ..) && active == run_id {
      return Some(conv)
    }
  }
  None
}

///|
/// The conversation that most recently owned run `run_id`, matched even after
/// the run finished. Used to route compaction events, which the engine stamps
/// with its last run id while sitting idle between turns.
fn Model::conversation_by_last_run(
  self : Model,
  run_id : String,
) -> Conversation? {
  for conv in self.conversations {
    if conv.last_run_id is Some(last) && last == run_id {
      return Some(conv)
    }
  }
  None
}

///|
/// Make `session_id` the on-screen conversation, creating its entry when it
/// has none, and drop conversations with nothing worth keeping — not
/// running, no transcript, no draft. Abandoned "New chat" husks die here
/// instead of accumulating invisible entries.
fn Model::activate(self : Model, session_id : String) -> Model {
  let conversations : Array[Conversation] = []
  let mut found = false
  for conv in self.conversations {
    if conv.session_id == session_id {
      found = true
      // Opening the conversation is what "seen" means.
      conversations.push({ ..conv, unseen_finish: false })
    } else if conv.is_running() ||
      conv.messages.length() > 0 ||
      conv.overlay.length() > 0 ||
      !conv.draft_empty() {
      conversations.push(conv)
    }
  }
  if !found {
    conversations.push(empty_conversation(session_id))
  }
  { ..self, active_session: session_id, conversations }
}

///|
/// Whether the composer draft holds nothing at all — no typed text and no
/// mention chips. This is the retention test (`Model::activate` keeps a
/// conversation whose draft still holds anything), not the send gate: that is
/// `draft_sendable`.
fn Conversation::draft_empty(self : Conversation) -> Bool {
  self.task.trim().is_empty() && self.mentions.is_empty()
}

///|
/// Whether the draft can be submitted: only typed text makes a prompt.
/// Chips alone don't send — a mention is context *for* an instruction, so
/// the instruction is required; the chips ride along in the envelope.
fn Conversation::draft_sendable(self : Conversation) -> Bool {
  !self.task.trim().is_empty()
}

///|
/// Whether the conversation has actually gotten under way — a run in flight,
/// or transcript items from one. A fresh "New chat" (even with a typed
/// draft) has not, and stays out of the sidebar until its first send.
fn Conversation::has_begun(self : Conversation) -> Bool {
  self.is_running() || self.messages.length() > 0 || self.overlay.length() > 0
}

///|
/// A run is in flight for this conversation — starting or open. The send
/// composer, sidebar pulse, and self-update busy check all gate on this.
fn Conversation::is_running(self : Conversation) -> Bool {
  !(self.run is NoRun(..))
}

///|
fn Conversation::clear_streams(self : Conversation) -> Conversation {
  { ..self, streaming_response: "", streaming_reasoning: "" }
}

///|
/// Append a display-only item after the durable transcript: everything the
/// live stream reports lands here first and joins `messages` only when its
/// durable commit arrives (which retires the overlay twin). Client-local
/// notices with no durable counterpart also live here — they last until the
/// next reload, exactly as long as they used to.
fn Conversation::append_overlay(
  self : Conversation,
  kind : @transcript.ItemKind,
  content : String,
) -> Conversation {
  let overlay = self.overlay.copy()
  overlay.push({ kind, content })
  { ..self, overlay, }
}

///|
/// What the transcript shows: the durable items, then the not-yet-committed
/// overlay.
fn Conversation::visible_items(
  self : Conversation,
) -> Array[@transcript.TranscriptItem] {
  if self.overlay.is_empty() {
    self.messages
  } else {
    self.messages + self.overlay
  }
}

///|
/// Apply one durable commit's item to the transcript and retire the overlay
/// items it settles: for each transcript item the commit renders as, the
/// first overlay item of the same kind drops (FIFO — the store commits in
/// the same order the live stream reported). Returns whether the transcript
/// visibly grew.
fn Conversation::apply_commit(
  self : Conversation,
  kind : String,
  payload : Map[String, Json],
) -> (Bool, Conversation) {
  let messages = self.messages.copy()
  let before = messages.length()
  @transcript.apply_session_item(messages, kind, payload)
  let mut overlay = self.overlay
  for index in before..<messages.length() {
    overlay = drop_first_overlay(overlay, messages[index].kind)
  }
  (messages.length() > before, { ..self, messages, overlay })
}

///|
/// Remove the first overlay item of `kind`'s class, if any — the durable
/// commit that just landed is its settled form.
fn drop_first_overlay(
  overlay : Array[@transcript.TranscriptItem],
  kind : @transcript.ItemKind,
) -> Array[@transcript.TranscriptItem] {
  for index, item in overlay {
    if same_item_class(item.kind, kind) {
      let next = overlay.copy()
      let _ = next.remove(index)
      return next
    }
  }
  overlay
}

///|
/// Kind classes for overlay retirement: constructor identity, payload
/// ignored (a tool card's durable form may brief itself differently than the
/// live event did).
fn same_item_class(a : @transcript.ItemKind, b : @transcript.ItemKind) -> Bool {
  match (a, b) {
    (User, User)
    | (Reasoning, Reasoning)
    | (Summary, Summary)
    | (Assistant(_), Assistant(_))
    | (Tool(..), Tool(..)) => true
    _ => false
  }
}

///|
/// Adopt a fresh `session.load` snapshot: it replaces the durable transcript
/// wholesale, clears the overlay (the snapshot is the settled truth for
/// everything committed so far — an overlay item it does not contain will
/// come back through its own commit), and drains the commits buffered while
/// the read was in flight. Returns the conversation and whether buffered
/// commits from beyond the snapshot failed to connect — a remaining gap the
/// caller answers with another read.
fn Conversation::adopt_snapshot(
  self : Conversation,
  items : Array[@transcript.TranscriptItem],
  watermark : Int,
) -> (Conversation, Bool) {
  let pending = match self.sync {
    Reloading(buffered~) => buffered.copy()
    Synced => []
  }
  // Sequence order, whatever the arrival order was.
  pending.sort_by((a, b) => a.sequence - b.sequence)
  let mut conv : Conversation = {
    ..self,
    messages: items,
    watermark,
    overlay: [],
    sync: Synced,
  }
  let leftover : Array[BufferedCommit] = []
  for commit in pending {
    if commit.sequence <= conv.watermark {
      continue
    }
    if commit.sequence == conv.watermark + 1 && leftover.is_empty() {
      let (_, next) = conv.apply_commit(commit.kind, commit.payload)
      conv = { ..next, watermark: commit.sequence }
    } else {
      leftover.push(commit)
    }
  }
  if leftover.is_empty() {
    (conv, false)
  } else {
    ({ ..conv, sync: Reloading(buffered=leftover) }, true)
  }
}

///|
/// The transcript notice for steering input that never reached the turn —
/// whether the engine rejected it (it raced the turn's end through the
/// pipes) or the run died with it unsettled. Either way the text must not
/// vanish silently.
fn steer_dropped_notice(text : String) -> String {
  "Input was not delivered (the task ended as you sent it) — submit it again: \{text}"
}

///|
/// Remove the first pending steer matching `text`. The engine settles steers
/// in wire order, but an identical-text steer must not steal a later one's
/// acknowledgment, so exactly one entry settles per event; no match (already
/// swept at run end) is a no-op.
fn Conversation::settle_pending_steer(
  self : Conversation,
  text : String,
) -> Conversation {
  for index, pending in self.pending_steers {
    if pending == text {
      let pending_steers = self.pending_steers.copy()
      let _ = pending_steers.remove(index)
      return { ..self, pending_steers, }
    }
  }
  self
}

///|
/// Surface every still-pending steer as a dropped notice and clear the list.
/// In the normal path the engine settles each steer before the turn's
/// terminal event, so this only fires when the run died with steers in
/// flight — the text must not vanish with it.
fn Conversation::sweep_pending_steers(self : Conversation) -> Conversation {
  let mut conv = self
  for text in self.pending_steers {
    conv = conv.append_overlay(Assistant(true), steer_dropped_notice(text))
  }
  { ..conv, pending_steers: [] }
}

///|
fn Conversation::last_assistant_content(self : Conversation) -> String? {
  let items = self.visible_items()
  if items.get(items.length() - 1) is Some(item) && item.kind is Assistant(_) {
    Some(item.content)
  } else {
    None
  }
}

///|
/// Severity of a status, used only to pick a CSS accent class.
priv enum StatusKind {
  Neutral
  Ok
  Warn
  Danger
}

///|
fn StatusKind::css(self : StatusKind) -> String {
  match self {
    Neutral => ""
    Ok => "ok"
    Warn => "warn"
    Danger => "danger"
  }
}

///|
/// How a run ended, parsed from the engine's wire status. An unrecognized
/// wire value survives as `Unknown` — a newer engine's statuses still get a
/// label, they just fall on the cautious side of every typed split.
priv enum RunOutcome {
  Completed
  ContextYield
  Aborted
  RunFailed
  Cancelled
  MaxStepsExhausted
  Unknown(String)
}

///|
fn RunOutcome::parse(wire : String) -> RunOutcome {
  match wire {
    "finished" => Completed
    "context_yield" => ContextYield
    "aborted" => Aborted
    "failed" => RunFailed
    "cancelled" => Cancelled
    "max_steps_exhausted" => MaxStepsExhausted
    other => Unknown(other)
  }
}

///|
fn RunOutcome::label(self : RunOutcome) -> String {
  match self {
    Completed => "Finished"
    ContextYield => "Context limit reached"
    Aborted => "Aborted"
    RunFailed => "Failed"
    Cancelled => "Cancelled"
    MaxStepsExhausted => "Max steps exhausted"
    // An empty wire status reads as a plain finish, like `parse`'s inverse.
    Unknown(wire) => if wire.trim().is_empty() { "Finished" } else { wire }
  }
}

///|
/// What the top bar shows, purely a display projection: `display_status`
/// derives it per render from the bridge state, the active conversation's
/// run phase, and the settings — nothing stores a `Status`, so the label and
/// its severity cannot drift from the state they describe.
priv enum Status {
  WaitingBridge
  Ready
  SetupRequired
  ApiKeyRequired
  Starting
  Running
  Cancelling
  // The engine's 1-based step counter; `None` for an engine build that does
  // not number its steps.
  Step(Int?)
  Failed
  Errored
  Finished(RunOutcome)
  Unavailable(String)
}

///|
fn Status::label(self : Status) -> String {
  match self {
    WaitingBridge => "Waiting for bridge"
    Ready => "Ready"
    SetupRequired => "Setup required"
    ApiKeyRequired => "API key required"
    Starting => "Starting"
    Running => "Running"
    Cancelling => "Cancelling"
    Step(step) => if step is Some(step) { "Step \{step}" } else { "Step" }
    Failed => "Failed"
    Errored => "Error"
    Finished(outcome) => outcome.label()
    Unavailable(message) => message
  }
}

///|
fn Status::kind(self : Status) -> StatusKind {
  match self {
    WaitingBridge => Neutral
    Ready => Ok
    SetupRequired
    | ApiKeyRequired
    | Starting
    | Running
    | Cancelling
    | Step(_) => Warn
    Failed | Errored | Unavailable(_) => Danger
    Finished(outcome) => if outcome is Completed { Ok } else { Warn }
  }
}
