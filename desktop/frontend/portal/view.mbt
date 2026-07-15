// The portal page. One list of device groups is the whole content: each
// group's header is the device — name, online state, console link, and the
// management actions behind a "⋯" menu — and its workspaces are the rows
// inside, each a link opening that device's console on that project.

///|
pub fn view(emit : @cmd.Emit[Msg], model : Model) -> @html.Html {
  let content : Array[@html.Html] = [header_bar(emit, model)]
  match model.auth {
    Checking =>
      content.push(
        @html.div(class="portal-card", [
          @html.p(
            match model.notice {
              Some(notice) => notice
              None => "Checking sign-in…"
            },
          ),
          match model.notice {
            Some(_) =>
              @html.button(class="primary", on_click=emit(Refresh), "Try again")
            None => @html.fragment([])
          },
        ]),
      )
    SignedOut =>
      content.push(
        @html.div(class="portal-card", [
          @html.h2("Sign in"),
          @html.p(
            "Your OpenSeek devices and their workspaces, from any browser.",
          ),
          @html.a(
            class="portal-button-link",
            href="/v1/auth/login?return_to=%2F",
            "Sign in with GitHub",
          ),
        ]),
      )
    SignedIn(login~, avatar~) => {
      ignore(avatar)
      ignore(login)
      content.push(devices_overview(emit, model))
      if model.notice is Some(notice) {
        content.push(@html.div(class="portal-notice", notice))
      }
    }
  }
  @html.section(class="portal", [@html.div(class="portal-inner", content)])
}

///|
fn header_bar(emit : @cmd.Emit[Msg], model : Model) -> @html.Html {
  let right : Array[@html.Html] = []
  if model.auth is SignedIn(login~, avatar~) {
    if !avatar.is_empty() {
      right.push(@html.img(class="portal-avatar", src=avatar, alt=login))
    }
    right.push(@html.span(class="portal-login", "@\{login}"))
    right.push(
      @html.button(
        class="secondary",
        disabled=model.busy,
        on_click=emit(Refresh),
        "Refresh",
      ),
    )
    right.push(
      @html.button(
        class="secondary",
        disabled=model.busy,
        on_click=emit(SignOutClicked),
        "Sign out",
      ),
    )
  }
  @html.header(class="portal-header", [
    @html.h1("OpenSeek"),
    @html.div(class="portal-header-right", right),
  ])
}

///|
/// Every device the account owns, one group per device, workspaces inside.
fn devices_overview(emit : @cmd.Emit[Msg], model : Model) -> @html.Html {
  let groups : Array[@html.Html] = []
  match model.devices {
    DevicesLoading =>
      groups.push(@html.p(class="portal-dim", "Loading devices…"))
    DevicesFailed(message) => groups.push(@html.p(class="portal-dim", message))
    DevicesReady(devices) => {
      if devices.length() == 0 {
        groups.push(
          @html.p(
            class="portal-dim",
            "No devices yet — open OpenSeek Desktop and sign in under Settings → Remote access.",
          ),
        )
      }
      for device in devices {
        groups.push(device_group(emit, model, device))
      }
    }
  }
  @html.div(class="portal-section", [
    @html.h2("Workspaces"),
    @html.div(class="portal-groups", groups),
  ])
}

///|
/// One device's card: the header row (identity, console link, "⋯" menu),
/// the menu when open, then the workspace rows.
fn device_group(
  emit : @cmd.Emit[Msg],
  model : Model,
  device : DeviceRow,
) -> @html.Html {
  let head : Array[@html.Html] = [
    @html.span(
      class=if device.online {
        "portal-device-dot online"
      } else {
        "portal-device-dot"
      },
      "",
    ),
  ]
  // The rename field replaces the identity block while editing. It renders
  // after the stable leading dot, and the group's position in the list does
  // not move, so the input keeps focus across re-renders.
  if model.rename is Some(rename) && rename.device == device.id {
    head.push(
      @html.input(
        class="portal-rename",
        value=rename.input,
        autofocus=true,
        on_input=emit.map(value => RenameEdited(value)),
        attrs=@html.Attrs::build().aria_label("Device name"),
      ),
    )
    head.push(
      @html.button(
        class="primary",
        disabled=model.busy || rename.input.trim().is_empty(),
        on_click=emit(RenameSubmitted),
        "Save",
      ),
    )
    head.push(
      @html.button(class="secondary", on_click=emit(RenameCancelled), "Cancel"),
    )
  } else {
    let title : Array[@html.Html] = [
      @html.span(class="portal-device-name", device.name),
    ]
    if device.hostname is Some(hostname) && hostname != device.name {
      title.push(@html.span(class="portal-device-host", hostname))
    }
    if !device.online {
      title.push(@html.span(class="portal-device-offline", "offline"))
    }
    head.push(@html.div(class="portal-device-title", title))
    head.push(
      @html.a(class="portal-open-link", href="/d/\{device.id}/", "Open console"),
    )
    head.push(
      @html.button(
        class="portal-menu-button",
        disabled=model.busy,
        title="Device actions",
        attrs=@html.Attrs::build().aria_label("Actions for \{device.name}"),
        on_click=emit(MenuToggled(device.id)),
        "⋯",
      ),
    )
  }
  let children : Array[@html.Html] = [
    @html.div(class="portal-device-head", head),
  ]
  if model.menu_open == Some(device.id) && model.rename is None {
    children.push(device_menu(emit, model, device))
  }
  workspace_rows(children, device)
  @html.div(class="portal-device-group", children)
}

///|
/// The "⋯" menu: Rename, and the two-click Remove — the confirmation
/// replaces the Remove item in place.
fn device_menu(
  emit : @cmd.Emit[Msg],
  model : Model,
  device : DeviceRow,
) -> @html.Html {
  let items : Array[@html.Html] = [
    @html.button(
      class="portal-menu-item",
      disabled=model.busy,
      on_click=emit(RenameStarted(device=device.id, current=device.name)),
      "Rename",
    ),
  ]
  if model.confirm_delete is Some(pending) && pending == device.id {
    items.push(
      @html.button(
        class="portal-menu-item danger",
        disabled=model.busy,
        on_click=emit(DeleteConfirmed(device.id)),
        "Really remove?",
      ),
    )
    items.push(
      @html.button(
        class="portal-menu-item",
        on_click=emit(DeleteCancelled),
        "Keep",
      ),
    )
  } else {
    items.push(
      @html.button(
        class="portal-menu-item danger",
        disabled=model.busy,
        on_click=emit(DeleteAsked(device.id)),
        "Remove",
      ),
    )
  }
  @html.div(class="portal-device-menu", items)
}

///|
/// The group's workspace rows (or the one line saying why there are none).
fn workspace_rows(children : Array[@html.Html], device : DeviceRow) -> Unit {
  match device.workspaces {
    NotProbed =>
      children.push(
        @html.p(
          class="portal-dim",
          "Offline — its workspaces will list again when it reconnects.",
        ),
      )
    Probing =>
      children.push(@html.p(class="portal-dim", "Asking for its workspaces…"))
    Unreachable =>
      children.push(
        @html.p(
          class="portal-dim",
          "Did not answer; open its console directly.",
        ),
      )
    Probed(workspaces) => {
      if workspaces.length() == 0 {
        children.push(
          @html.a(class="portal-workspace", href="/d/\{device.id}/", [
            @html.span(class="portal-workspace-name", "New conversation"),
          ]),
        )
      }
      for workspace in workspaces {
        children.push(
          @html.a(
            class="portal-workspace",
            href="/d/\{device.id}/?workspace=\{@interop.encode_query_component(workspace)}",
            [
              @html.span(
                class="portal-workspace-name",
                workspace_basename(workspace),
              ),
              @html.span(class="portal-workspace-path", workspace),
            ],
          ),
        )
      }
    }
  }
}

///|
fn workspace_basename(path : String) -> String {
  let trimmed = match path.strip_suffix("/") {
    Some(rest) => rest.to_owned()
    None => path
  }
  match trimmed.rev_find("/") {
    Some(index) => trimmed[index + 1:].to_owned()
    None => trimmed
  }
}
