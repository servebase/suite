# user facing credit page: balance, spend, top up, ledger.
#
# every number shown here comes from the server on each action rather than
# being adjusted locally - the ledger is the source of truth and a stale local
# copy of a balance is exactly the kind of thing that quietly goes wrong.

# navtop is an ldc module, and an ldc module is only instantiated when some app
# declares it as a dependency - loading its script does nothing on its own.
# `servebase.corectx` only declares `core`, so the bar has to be pulled in here
# or it renders as static markup that never learns who is signed in.
ldc.init ldc.register <[navtop]>, ->

<- servebase.corectx _
core = @

lc =
  balance: {}
  plans: []
  subscription: null
  pay: {}
  ldcv: {}
  price: []
  jobs: []
  log: {list: [], count: 0, limit: 20, offset: 0}
  "topup-max": 500
  "grant-ttl": null

datefmt = (t) ->
  if !t => return ''
  if httputil?datefmt => httputil.datefmt t else new Date(t).toLocaleString!

# consume rows carry the feature in source_type; grants carry a ref instead.
detail-of = (d) ->
  [d.source_type, (if d.memo => "\"#{d.memo}\"" else null)].filter(->it).join ' '

fetch-plans = ->
  ld$.fetch \/api/demo/plan, {method: \GET}, {type: \json}
    .then (r = {}) -> lc.plans = r.list or []

fetch-subscription = ->
  ld$.fetch \/api/demo/subscription, {method: \GET}, {type: \json}
    .then (r = {}) -> lc.subscription = r.subscription or null

fetch-balance = ->
  ld$.fetch \/api/credit, {method: \GET}, {type: \json}
    .then (r = {}) -> lc.balance = r

fetch-price = ->
  ld$.fetch \/api/demo/price, {method: \GET}, {type: \json}
    .then (r = {}) ->
      lc.price = Object.entries(r.price or {}).map ([name, cost]) -> {name, cost}
      if r.topupMax => lc.topup-max = r.topupMax
      if r.grantTtl? => lc.grant-ttl = r.grantTtl

fetch-jobs = ->
  ld$.fetch \/api/demo/job, {method: \GET}, {type: \json}
    .then (r = {}) -> lc.jobs = (r.list or []).slice 0, 5

fetch-log = ({offset} = {}) ->
  if offset? => lc.log.offset = Math.max 0, offset
  qs = "limit=#{lc.log.limit}&offset=#{lc.log.offset}"
  ld$.fetch "/api/credit/log?#qs", {method: \GET}, {type: \json}
    .then (r = {}) -> lc.log = {limit: lc.log.limit} <<< r

reload = ->
  Promise.all [fetch-balance!, fetch-jobs!, fetch-log!, fetch-subscription!]
    .then -> view.render!

# the dialog is a cover, so this reads as a straight line: show it, wait for the
# answer, and only then call the server. `data-ldcv-set` on the two buttons is
# what resolves the promise.
subscribe = (plan) ->
  lc.pay = plan
  view.render \pay-plan, \pay-price, \pay-credits
  (ret) <- lc.ldcv.pay.get!then _
  if ret != \pay => return
  core.loader.on!
  ld$.fetch \/api/demo/subscription, {method: \POST}, {json: {plan: plan.key}, type: \json}
    .then -> ldnotify.send \success, "subscribed to #{plan.name}."
    .then -> reload!
    .catch (e) ->
      if lderror.id(e) == 1014 => return ldnotify.send \warning, "already subscribed."
      Promise.reject e
    .finally -> core.loader.off!

sub-action = (path, ok) ->
  core.loader.on!
  ld$.fetch "/api/demo/subscription/#path", {method: \POST}, {json: {}, type: \json}
    .then -> ldnotify.send \success, ok
    .then -> reload!
    .finally -> core.loader.off!

# insufficient credit is an expected outcome of a demo, not a crash: report it
# inline and let anything else fall through to the core error handler.
guard = (p) -> p.catch (e) ->
  if lderror.id(e) == 402 => return ldnotify.send \warning, "not enough credit."
  Promise.reject e

view = new ldview do
  root: document.body
  init:
    ldcv: ({node}) -> lc.ldcv[node.dataset.name] = new ldcover root: node, resident: true
  text:
    usable: -> lc.balance.usableBalance or 0
    subscription: -> lc.balance.subscription or 0
    purchase: -> lc.balance.purchase or 0
    "topup-max": -> lc.topup-max
    "topup-ttl-note": -> if lc.grant-ttl? => "#{lc.grant-ttl} days after purchase by default" else "never by default"
    "log-count": -> lc.log.count or 0
    "sub-state": -> if lc.subscription => lc.subscription.state else 'none'
    "sub-plan": -> if lc.subscription => lc.subscription.plan_name else '-'
    "sub-period": -> if lc.subscription => lc.subscription.period else '-'
    "sub-note": ->
      if !lc.subscription => return ''
      # the gate is the whole point of `canceled` being its own state, so say
      # out loud what it means for the balance sitting above.
      switch lc.subscription.state
      | \canceled =>
        "Canceled. The period you already paid for still runs, so these credits stay spendable until it ends."
      | \suspended =>
        "Suspended. The credits below are still yours and still counted - they just cannot be spent until the subscription is active again. Nothing was taken away."
      | _ =>
        "#{lc.subscription.credits} credits are granted at the start of every period."
    "pay-plan": -> lc.pay.name or '-'
    "pay-price": -> if lc.pay.price? => "#{lc.pay.price} #{lc.pay.currency or ''}" else '-'
    "pay-credits": -> lc.pay.credits or '-'
    "log-range": ->
      if !(lc.log.list or []).length => return 0
      "#{lc.log.offset + 1} ~ #{lc.log.offset + lc.log.list.length}"
  handler:
    # the pool is only worth flagging when it holds credits that cannot be spent.
    gated: ({node}) ->
      gated = (lc.balance.subscription or 0) > 0 and !(lc.balance.usableSubscription or 0)
      node.classList.toggle \d-none, !gated
    "no-log": ({node}) -> node.classList.toggle \d-none, !!(lc.log.list or []).length
    "sub-state-chip": ({node}) ->
      node.classList.toggle \text-danger, (lc.subscription?state == \suspended)
    "sub-none": ({node}) -> node.classList.toggle \d-none, !!lc.subscription
    "sub-live": ({node}) -> node.classList.toggle \d-none, !lc.subscription
    plan:
      list: -> lc.plans or []
      key: -> it.key
      view:
        text:
          "plan-name": ({ctx}) -> ctx.name
          "plan-price": ({ctx}) -> "#{ctx.price} / #{ctx.frequency}"
        action: click:
          subscribe: ({ctx}) -> subscribe ctx
    "no-job": ({node}) -> node.classList.toggle \d-none, !!(lc.jobs or []).length
    pager: ({node}) -> node.classList.toggle \d-none, (lc.log.count or 0) <= lc.log.limit
    price:
      list: -> lc.price or []
      key: -> it.name
      view:
        text:
          name: ({ctx}) -> ctx.name
          cost: ({ctx}) -> ctx.cost
        action: click:
          buy: ({ctx}) ->
            core.loader.on!
            guard ld$.fetch("/api/demo/job", {method: \POST}, {json: {name: ctx.name}, type: \json})
              .then (r) -> if r => ldnotify.send \success, "spent #{r.cost} credits."
              .then -> reload!
              .finally -> core.loader.off!
    job:
      list: -> lc.jobs or []
      key: -> it.key
      view: text:
        name: ({ctx}) -> "#{ctx.name} (#{ctx.cost} cr)"
        time: ({ctx}) -> datefmt ctx.createdtime
    log:
      list: -> lc.log.list or []
      key: -> it.key
      view: text:
        time: ({ctx}) -> datefmt ctx.createdtime
        action: ({ctx}) -> ctx.action
        pool: ({ctx}) -> ctx.pool
        delta: ({ctx}) -> if ctx.delta > 0 => "+#{ctx.delta}" else "#{ctx.delta}"
        after: ({ctx}) -> ctx.total_balance
        detail: ({ctx}) -> detail-of ctx
  action: click:
    topup: ->
      amount = +(view.get(\topup-amount).value or 0)
      if !amount or isNaN(amount) or amount <= 0 => return ldnotify.send \warning, "enter an amount."
      # "" means send nothing and let the site default apply; "never" sends an
      # explicit null, which is the only way to beat that default.
      choice = view.get(\topup-ttl).value
      json = {amount}
      if choice == \never => json.ttl = null
      else if choice != '' => json.ttl = +choice
      core.loader.on!
      ld$.fetch "/api/demo/topup", {method: \POST}, {json, type: \json}
        .then -> ldnotify.send \success, "topped up #amount credits."
        .then -> reload!
        .finally -> core.loader.off!
    "cancel-sub": -> sub-action \cancel, "subscription canceled."
    advance: -> sub-action \advance, "advanced one period."
    page: ({node}) ->
      dir = node.dataset.dir
      offset = lc.log.offset + (if dir == \next => lc.log.limit else -lc.log.limit)
      if offset < 0 or offset >= (lc.log.count or 0) => return
      fetch-log {offset} .then -> view.render!

Promise.all [fetch-price!, fetch-plans!, fetch-balance!, fetch-jobs!, fetch-log!, fetch-subscription!]
  .then -> view.render!
