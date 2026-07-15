// The portal page. One flat list of workspaces across every online device
// is the main content — a workspace is what the user comes to open; the
// devices themselves are the management section below it.

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
      content.push(workspaces_section(model))
      content.push(devices_section(emit, model))
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
/// Every online device's workspaces, flattened. Each row opens that
/// device's console with the workspace preselected (`?workspace=`).
fn workspaces_section(model : Model) -> @html.Html {
  let rows : Array[@html.Html] = []
  match model.devices {
    DevicesLoading =>
      rows.push(@html.p(class="portal-dim", "Loading devices…"))
    DevicesFailed(message) => rows.push(@html.p(class="portal-dim", message))
    DevicesReady(devices) => {
      let mut online = 0
      for device in devices {
        if !device.online {
          continue
        }
        online = online + 1
        match device.workspaces {
          NotProbed | Probing =>
            rows.push(
              @html.p(
                class="portal-dim",
                "\{device.name} — asking for its workspaces…",
              ),
            )
          Unreachable =>
            rows.push(
              @html.p(
                class="portal-dim",
                "\{device.name} — did not answer; open its console directly below.",
              ),
            )
          Probed(workspaces) => {
            if workspaces.length() == 0 {
              rows.push(
                @html.a(class="portal-workspace", href="/d/\{device.id}/", [
                  @html.span(class="portal-workspace-name", "New conversation"),
                  @html.span(class="portal-workspace-device", device.name),
                ]),
              )
            }
            for workspace in workspaces {
              rows.push(
                @html.a(
                  class="portal-workspace",
                  href="/d/\{device.id}/?workspace=\{@interop.encode_query_component(workspace)}",
                  [
                    @html.span(
                      class="portal-workspace-name",
                      workspace_basename(workspace),
                    ),
                    @html.span(class="portal-workspace-path", workspace),
                    @html.span(class="portal-workspace-device", device.name),
                  ],
                ),
              )
            }
          }
        }
      }
      if online == 0 {
        rows.push(
          @html.p(
            class="portal-dim",
            "No device is online. Open OpenSeek Desktop and sign in under Settings → Remote access.",
          ),
        )
      }
    }
  }
  @html.div(class="portal-section", [
    @html.h2("Workspaces"),
    @html.div(class="portal-list", rows),
  ])
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

///|
/// The device management list: every device the account owns, online or
/// not, with rename and revoke.
fn devices_section(emit : @cmd.Emit[Msg], model : Model) -> @html.Html {
  let rows : Array[@html.Html] = []
  match model.devices {
    DevicesLoading => ()
    DevicesFailed(_) => ()
    DevicesReady(devices) => {
      if devices.length() == 0 {
        rows.push(
          @html.p(
            class="portal-dim",
            "No devices yet — sign in from OpenSeek Desktop to register one.",
          ),
        )
      }
      for device in devices {
        rows.push(device_row(emit, model, device))
      }
    }
  }
  @html.div(class="portal-section", [
    @html.h2("Devices"),
    @html.div(class="portal-list", rows),
  ])
}

///|
fn device_row(
  emit : @cmd.Emit[Msg],
  model : Model,
  device : DeviceRow,
) -> @html.Html {
  let children : Array[@html.Html] = [
    @html.span(
      class=if device.online {
        "portal-device-dot online"
      } else {
        "portal-device-dot"
      },
      "",
    ),
  ]
  // The rename field replaces the name label while editing. It renders
  // after the stable leading children, and the row's identity in the list
  // does not move, so the input keeps focus across re-renders.
  if model.rename is Some(rename) && rename.device == device.id {
    children.push(
      @html.input(
        class="portal-rename",
        value=rename.input,
        autofocus=true,
        on_input=emit.map(value => RenameEdited(value)),
      ),
    )
    children.push(
      @html.button(
        class="primary",
        disabled=model.busy || rename.input.trim().is_empty(),
        on_click=emit(RenameSubmitted),
        "Save",
      ),
    )
    children.push(
      @html.button(class="secondary", on_click=emit(RenameCancelled), "Cancel"),
    )
  } else {
    children.push(@html.span(class="portal-device-name", device.name))
    if device.hostname is Some(hostname) && hostname != device.name {
      children.push(@html.span(class="portal-dim", hostname))
    }
    children.push(
      @html.a(class="portal-open-link", href="/d/\{device.id}/", "Open console"),
    )
    children.push(
      @html.button(
        class="secondary",
        disabled=model.busy,
        on_click=emit(RenameStarted(device=device.id, current=device.name)),
        "Rename",
      ),
    )
    if model.confirm_delete is Some(pending) && pending == device.id {
      children.push(
        @html.button(
          class="danger",
          disabled=model.busy,
          on_click=emit(DeleteConfirmed(device.id)),
          "Really remove?",
        ),
      )
      children.push(
        @html.button(class="secondary", on_click=emit(DeleteCancelled), "Keep"),
      )
    } else {
      children.push(
        @html.button(
          class="secondary",
          disabled=model.busy,
          on_click=emit(DeleteAsked(device.id)),
          "Remove",
        ),
      )
    }
  }
  @html.div(class="portal-device", children)
}
