# staff account console: search / create / batch-update accounts, and adjust a
# selected account's credit.
#
# selection is kept as a key -> true map rather than a flag on the row objects,
# so a selection survives paging and sorting; the batch call sends keys, and the
# server is the one that refuses staff accounts and self-inflicted damage.

# navtop is an ldc module, and an ldc module is only instantiated when some app
# declares it as a dependency - loading its script does nothing on its own.
# `servebase.corectx` only declares `core`, so the bar has to be pulled in here
# or it renders as static markup that never learns who is signed in.
ldc.init ldc.register <[navtop]>, ->

<- servebase.corectx _
core = @

ACTION-LABEL =
  verify: "mark verified"
  unverify: "mark unverified"
  logout: "sign out of every session"
  "password-reset": "reset the password"
  delete: "delete"

lc =
  user: [], count: 0, limit: 20, offset: 0
  sort: {base: \key, sign: {}}
  check: {}
  ldcv: {}
  confirm: {title: '', desc: ''}
  result: []
  credit: {user: null, balance: {}, log: [], purchases: [], subscription: null}

datefmt = (t) ->
  if !t => return ''
  if httputil?datefmt => httputil.datefmt t else new Date(t).toLocaleString!

detail-of = (d) -> [d.source_type, (if d.memo => "\"#{d.memo}\"" else null)].filter(->it).join ' '

checked-keys = -> Object.keys(lc.check).filter(-> lc.check[it]).map -> +it

search = ({offset, reset} = {}) ->
  if reset => lc.offset = 0
  if offset? => lc.offset = Math.max 0, offset
  json =
    query: (view.get(\keyword).value or '').trim!
    limit: lc.limit, offset: lc.offset
    sort: lc.sort.base, desc: (lc.sort.sign[lc.sort.base] or -1) > 0
  ld$.fetch "/api/staff/user/lookup", {method: \POST}, {json, type: \json}
    .then (r = {}) ->
      lc <<< {user: (r.list or []), count: (r.count or 0), offset: (r.offset or 0)}
      view.render!

confirm = ({title, desc}) ->
  lc.confirm = {title, desc}
  view.render \confirm-title, \confirm-desc
  lc.ldcv.confirm.get!

show-result = (list) ->
  lc.result = list
  view.render \result
  lc.ldcv.result.get!

batch = (action) ->
  keys = checked-keys!
  if !keys.length => return
  p = if action in <[delete password-reset]>
    confirm {
      title: "#{ACTION-LABEL[action]}?"
      desc: "This applies to #{keys.length} account(s) and cannot be undone."
    }
  else Promise.resolve \yes
  p.then (ret) ->
    if ret != \yes => return
    core.loader.on!
    ld$.fetch "/api/staff/user/update", {method: \POST}, {json: {keys, action}, type: \json}
      .then (r = {}) ->
        list = r.list or []
        # a partial failure is normal here (staff accounts, own account), so the
        # result table is always shown rather than a bare success toast.
        lc.check = {}
        search!.then -> show-result list
      .finally -> core.loader.off!

open-credit = (user) ->
  lc.credit = {user, balance: {}, log: [], purchases: [], subscription: null}
  core.loader.on!
  fetch-credit user.key
    .finally -> core.loader.off!
    .then -> lc.ldcv.credit.get!

# one place that reloads everything the credit cover shows. balance, ledger and
# purchases all move together on any action, and refreshing only the one the
# action touched is how a panel starts lying about the other two.
fetch-credit = (key) ->
  Promise.all [
    ld$.fetch "/api/credit/staff/user/#key", {method: \GET}, {type: \json}
    ld$.fetch "/api/credit/staff/log?owner=#key&limit=50", {method: \GET}, {type: \json}
    ld$.fetch "/api/staff/credit/purchase/#key", {method: \GET}, {type: \json}
    ld$.fetch "/api/staff/subscription/#key", {method: \GET}, {type: \json}
  ]
    .then ([balance = {}, log = {}, purchase = {}, sub = {}]) ->
      lc.credit <<< {
        balance, log: (log.list or []), purchases: (purchase.list or [])
        subscription: (sub.subscription or null)
      }
      view.render!

reload-credit = ->
  if !lc.credit.user => return Promise.resolve!
  fetch-credit lc.credit.user.key

refund-purchase = (p) ->
  if !(remaining = p.remaining or 0) => return
  memo = (view.get('refund.memo').value or '').trim!
  if !memo => return ldnotify.send \warning, "a refund reason is required."
  desc = "Purchase ##{p.key} granted #{p.amount} credits; #remaining is still unspent, "
  desc += "and that is all a refund can take back."
  (ret) <- confirm({title: "refund #remaining credits?", desc}).then _
  if ret != \yes => return
  json = {owner: lc.credit.user.key, purchase: p.key, memo}
  core.loader.on!
  ld$.fetch "/api/staff/credit/refund", {method: \POST}, {json, type: \json}
    .then (r = {}) ->
      view.get('refund.memo').value = ''
      ldnotify.send \success, "refunded #{r.refunded} of #{r.requested}."
    .then -> reload-credit!
    .finally -> core.loader.off!

view = new ldview do
  root: document.body
  init:
    ldcv: ({node}) -> lc.ldcv[node.dataset.name] = new ldcover root: node, resident: true
  text:
    count: -> lc.count or 0
    range: ->
      if !(lc.user or []).length => return 0
      "#{lc.offset + 1} ~ #{lc.offset + lc.user.length}"
    "check-count": -> checked-keys!length
    "confirm-title": -> lc.confirm.title
    "confirm-desc": -> lc.confirm.desc
    "credit-user": -> if lc.credit.user => "#{lc.credit.user.username} (##{lc.credit.user.key})" else ''
    "credit-usable": -> lc.credit.balance.usableBalance or 0
    "credit-subscription": -> lc.credit.balance.subscription or 0
    "credit-purchase": -> lc.credit.balance.purchase or 0
  handler:
    "is-empty": ({node}) -> node.classList.toggle \d-none, !!(lc.user or []).length
    "not-empty": ({node}) -> node.classList.toggle \d-none, !(lc.user or []).length
    "has-checks": ({node}) -> node.classList.toggle \d-none, !checked-keys!length
    pager: ({node}) -> node.classList.toggle \d-none, (lc.count or 0) <= lc.limit
    "credit-no-log": ({node}) -> node.classList.toggle \d-none, !!(lc.credit.log or []).length
    # tri-state against the current page only: "all" means every visible row.
    "check-all-icon": ({node}) ->
      list = lc.user or []
      rate = list.filter(-> lc.check[it.key]).length / (list.length or 1)
      node.classList.toggle \i-checkbox-semi, (rate > 0 and rate < 1)
      node.classList.toggle \i-checkbox-on, (rate == 1 and !!list.length)
      node.classList.toggle \i-checkbox-off, (rate == 0 or !list.length)
    "sort-indicator": ({node}) ->
      field = node.parentNode.dataset.field
      node.classList.toggle \d-none, (lc.sort.base != field)
      node.classList.toggle \i-dart-down, (lc.sort.sign[field] > 0)
      node.classList.toggle \i-dart-up, !(lc.sort.sign[field] > 0)
    user:
      list: -> lc.user or []
      key: -> it.key
      view:
        text:
          key: ({ctx}) -> ctx.key
          username: ({ctx}) -> ctx.username
          displayname: ({ctx}) -> ctx.displayname or ''
          createdtime: ({ctx}) -> datefmt ctx.createdtime
        handler:
          "check-icon": ({node, ctx}) ->
            node.classList.toggle \i-checkbox-on, !!lc.check[ctx.key]
            node.classList.toggle \i-checkbox-off, !lc.check[ctx.key]
          verified: ({node, ctx}) ->
            ok = !!ctx.verified?date
            node.innerText = if ok => 'yes' else 'no'
            node.classList.toggle \badge-success, ok
            node.classList.toggle \badge-light, !ok
        action: click:
          check: ({ctx, views}) ->
            lc.check[ctx.key] = !lc.check[ctx.key]
            views.0.render!
            views.1.render \has-checks, \check-count, \check-all-icon
          credit: ({ctx}) -> open-credit ctx
    result:
      list: -> lc.result or []
      key: -> it.key
      view: text:
        username: ({ctx}) -> ctx.username or "##{ctx.key}"
        state: ({ctx}) -> ctx.result
        password: ({ctx}) -> ctx.password or ''
    "no-purchase": ({node}) -> node.classList.toggle \d-none, !!(lc.credit.purchases or []).length
    "sub-live": ({node}) -> node.classList.toggle \d-none, !lc.credit.subscription
    "sub-info": ({node}) ->
      s = lc.credit.subscription
      node.innerText =
        if !s => "no subscription"
        else "#{s.plan_name} · #{s.state} · period #{s.period}"
      node.classList.toggle \text-muted, !s
      node.classList.toggle \text-danger, (!!s and s.state == \suspended)
    # the current state is not a button: pressing it would be a no-op request.
    "sub-state": ({node}) ->
      s = lc.credit.subscription
      node.classList.toggle \disabled, (!!s and s.state == node.dataset.state)
    purchase:
      list: -> lc.credit.purchases or []
      key: -> it.key
      view:
        text:
          pkey: ({ctx}) -> "##{ctx.key}"
          pamount: ({ctx}) -> ctx.amount
          pprice: ({ctx}) -> if ctx.price? => "#{ctx.price} #{ctx.currency or ''}" else ''
          ptime: ({ctx}) -> datefmt ctx.createdtime
          pexpire: ({ctx}) ->
            if !ctx.expiretime => "never expires"
            else if ctx.due => "expired"
            else "expires #{datefmt ctx.expiretime}"
        handler:
          # state is derived, not stored: refunded against amount says it all,
          # and `remaining` is what a refund could still take back.
          pstate: ({node, ctx}) ->
            [amount, refunded, remaining] = [ctx.amount, (ctx.refunded or 0), (ctx.remaining or 0)]
            full = refunded >= amount
            node.innerText =
              if full => "refunded"
              else if refunded > 0 => "partial #refunded/#amount"
              else "paid / #remaining left"
            node.classList.toggle \badge-secondary, full
            node.classList.toggle \badge-warning, (refunded > 0 and !full)
            node.classList.toggle \badge-light, !refunded
          prefund: ({node, ctx}) ->
            node.classList.toggle \disabled, !(ctx.remaining or 0)
          pexpire: ({node, ctx}) ->
            node.classList.toggle \text-muted, !ctx.expiretime
            node.classList.toggle \text-danger, !!ctx.due
            node.classList.toggle \text-sm, true
        action: click:
          prefund: ({ctx}) -> refund-purchase ctx
    "credit-log":
      list: -> lc.credit.log or []
      key: -> it.key
      view: text:
        time: ({ctx}) -> datefmt ctx.createdtime
        action: ({ctx}) -> ctx.action
        pool: ({ctx}) -> ctx.pool
        delta: ({ctx}) -> if ctx.delta > 0 => "+#{ctx.delta}" else "#{ctx.delta}"
        after: ({ctx}) -> ctx.total_balance
        detail: ({ctx}) -> detail-of ctx
  action: click:
    search: -> search {reset: true}
    clear: ->
      view.get(\keyword).value = ''
      lc.check = {}
      search {reset: true}
    sort: ({node}) ->
      field = node.dataset.field
      lc.sort.sign[field] = -(lc.sort.sign[field] or -1)
      lc.sort.base = field
      search {reset: true}
    page: ({node}) ->
      offset = lc.offset + (if node.dataset.dir == \next => lc.limit else -lc.limit)
      if offset < 0 or offset >= (lc.count or 0) => return
      search {offset}
    "check-all": ->
      list = lc.user or []
      on-now = list.filter(-> lc.check[it.key]).length == list.length
      list.for-each -> lc.check[it.key] = !on-now
      view.render!
    action: ({node}) -> batch node.dataset.name
    "add-user": ->
      <[username displayname password]>.map -> view.get("add.#it").value = ''
      view.get('add.verified').checked = true
      lc.ldcv['add-user'].get!
    "add-submit": ->
      json =
        username: view.get('add.username').value
        displayname: view.get('add.displayname').value
        password: view.get('add.password').value
        verified: !!view.get('add.verified').checked
      if !json.username => return ldnotify.send \warning, "e-mail is required."
      core.loader.on!
      ld$.fetch "/api/staff/user", {method: \POST}, {json, type: \json}
        .then (r = {}) ->
          lc.ldcv['add-user'].set!
          search {reset: true}
            .then -> show-result [{key: r.key, username: r.username, result: \ok, password: r.password}]
        .catch (e) ->
          # 1014 user existed / 1015 bad e-mail: the operator can fix both here.
          if lderror.id(e) == 1014 => return ldnotify.send \warning, "that account already exists."
          if lderror.id(e) == 1015 => return ldnotify.send \warning, "that is not a valid e-mail."
          Promise.reject e
        .finally -> core.loader.off!
    "adjust-submit": ->
      if !lc.credit.user => return
      json =
        owner: lc.credit.user.key
        pool: view.get('adjust.pool').value
        delta: +(view.get('adjust.delta').value or 0)
        memo: (view.get('adjust.memo').value or '').trim!
      if !json.delta or isNaN(json.delta) => return ldnotify.send \warning, "enter a non-zero delta."
      if !json.memo => return ldnotify.send \warning, "a memo is required."
      core.loader.on!
      ld$.fetch "/api/credit/staff/adjust", {method: \POST}, {json, type: \json}
        .then ->
          view.get('adjust.delta').value = ''
          view.get('adjust.memo').value = ''
          ldnotify.send \success, "adjusted."
        .then -> reload-credit!
        .catch (e) ->
          if lderror.id(e) == 400 => return ldnotify.send \warning, "adjustment rejected - check the balance and memo."
          Promise.reject e
        .finally -> core.loader.off!
    sub: ({node}) ->
      if !lc.credit.user => return
      json = {owner: lc.credit.user.key, action: node.dataset.action, frequency: node.dataset.frequency}
      core.loader.on!
      ld$.fetch "/api/staff/credit/sub", {method: \POST}, {json, type: \json}
        .then -> reload-credit!
        .finally -> core.loader.off!
    "sub-state": ({node}) ->
      if !lc.credit.user or !lc.credit.subscription => return
      state = node.dataset.state
      if state == lc.credit.subscription.state => return
      core.loader.on!
      json = {owner: lc.credit.user.key, state}
      ld$.fetch "/api/staff/subscription", {method: \POST}, {json, type: \json}
        .then -> ldnotify.send \success, "subscription set to #state."
        .then -> reload-credit!
        .finally -> core.loader.off!
    "run-expire": ->
      if !lc.credit.user => return
      core.loader.on!
      json = {owner: lc.credit.user.key}
      ld$.fetch "/api/staff/credit/expire", {method: \POST}, {json, type: \json}
        .then (r = {}) ->
          ldnotify.send (if r.expired => \success else \warning),
            (if r.expired => "expired #{r.expired} credits across #{r.grants} grant(s)."
             else "nothing was due.")
        .then -> reload-credit!
        .finally -> core.loader.off!
    "refund-sub": ->
      if !lc.credit.user => return
      memo = (view.get('subrefund.memo').value or '').trim!
      if !memo => return ldnotify.send \warning, "a reason is required."
      json = {owner: lc.credit.user.key, memo}
      core.loader.on!
      ld$.fetch "/api/staff/credit/refund-sub", {method: \POST}, {json, type: \json}
        .then (r = {}) ->
          view.get('subrefund.memo').value = ''
          # `consumed` is the number an all-or-nothing policy would refuse on, so
          # it is reported rather than hidden behind a bare success message.
          ldnotify.send (if r.refunded => \success else \warning),
            "granted #{r.granted}, consumed #{r.consumed}, refunded #{r.refunded}."
        .then -> reload-credit!
        .catch (e) ->
          if lderror.id(e) == 404 => return ldnotify.send \warning, "no subscription grant to refund."
          Promise.reject e
        .finally -> core.loader.off!
    reconcile: ->
      if !lc.credit.user => return
      core.loader.on!
      ld$.fetch "/api/credit/staff/reconcile?owner=#{lc.credit.user.key}", {method: \GET}, {type: \json}
        .then (r = {}) ->
          n = (r.list or []).length
          ldnotify.send (if n => \danger else \success),
            (if n => "#n mismatch(es) - balance disagrees with the ledger" else "consistent.")
        .finally -> core.loader.off!
    "copy-result": ->
      tsv = (lc.result or [])
        .map -> [(it.username or it.key), it.result, (it.password or '')].join "\t"
        .join "\n"
      navigator.clipboard.write-text tsv
      ldnotify.send \success, "copied."

search!
