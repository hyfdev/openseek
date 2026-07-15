///|
#warnings("-alert_unstable")
fn main {
  let (dispatch, cell) = @rabbita.cell_with_emit(
    model=initial_model(),
    update~,
    view~,
    // The narrow-layout flag must track the window: rotating a phone or
    // resizing a desktop window across the breakpoint re-lays the app out.
    subscriptions=(emit, _) => {
      @sub.on_resize(
        emit.map(viewport => ViewportResized(width=viewport.width)),
      )
    },
  )
  let app = @rabbita.new(cell)
  app.with_init(dispatch(Init))
  app.mount("app")
}
