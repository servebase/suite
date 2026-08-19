# landing page: everything here is driven by the auth state core already loaded,
# so no extra request is made just to decide what to show.

# navtop is an ldc module, and an ldc module is only instantiated when some app
# declares it as a dependency - loading its script does nothing on its own.
# `servebase.corectx` only declares `core`, so the bar has to be pulled in here
# or it renders as static markup that never learns who is signed in.
ldc.init ldc.register <[navtop]>, ->

<- servebase.corectx _
core = @

signed = -> !!core.user?key
staff = -> core.user?staff == 1

view = new ldview do
  root: document.body
  text:
    who: -> core.user?displayname or core.user?username or '-'
  handler:
    "signed-in": ({node}) -> node.classList.toggle \d-none, !signed!
    "signed-out": ({node}) -> node.classList.toggle \d-none, signed!
    "staff-note": ({node}) -> node.classList.toggle \d-none, !staff!
    "credit-link": ({node}) -> node.classList.toggle \d-none, !signed!
    "credit-hint": ({node}) -> node.classList.toggle \d-none, signed!
    "staff-link": ({node}) -> node.classList.toggle \d-none, !staff!
    "staff-hint": ({node}) -> node.classList.toggle \d-none, staff!
  action: click:
    login: -> core.auth.prompt {tab: \login}
    signup: -> core.auth.prompt {tab: \signup}

core.auth.on \update, -> view.render!
view.render!
