# demo subscription: plans, a stand-in payment, cancel, and a button that does
# what a billing cron would.
#
# nothing here is a payment integration. the point is to give the credit module
# something real to gate on, so that the difference between the subscription and
# purchase pools is visible instead of theoretical.

require! <[lderror @servebase/backend/aux]>
(backend) <- (->module.exports = it)  _
{db, route: {api}} = backend

credit = -> backend.mod.credit

pad = (n) -> if n < 10 => "0#n" else "#n"

this-period = ->
  d = new Date!
  "#{d.getFullYear!}-#{pad d.getMonth! + 1}"

# periods are 'YYYY-MM' for both frequencies; a yearly plan simply steps 12 of
# them at once, so one column describes both and the idempotency guard on
# (ref, period) keeps working either way.
next-period = (period, frequency) ->
  [y, m] = "#period".split('-').map -> +it
  if isNaN(y) or isNaN(m) => return this-period!
  m += (if frequency == \year => 12 else 1)
  y += Math.floor((m - 1) / 12)
  m = ((m - 1) % 12) + 1
  "#{y}-#{pad m}"

live = (owner) ->
  db.query """
  select s.*, p.name as plan_name, p.frequency, p.price, p.currency, p.credits
  from subscription s join plan p on p.key = s.plan
  where s.owner = $1 and s.state <> 'expired'
  limit 1
  """, [owner]
    .then (r = {}) -> r.[]rows.0 or null

api.get \/demo/plan, (req, res) ->
  db.query "select * from plan order by ordering, key"
    .then (r = {}) -> res.send {list: r.[]rows}

api.get \/demo/subscription, aux.signedin, (req, res) ->
  live req.user.key .then (subscription) -> res.send {subscription}

# "payment". a real site reaches this from a verified gateway callback, never
# from a button - which is why the frontend dialog says so in large letters.
api.post \/demo/subscription, aux.signedin, (req, res) ->
  owner = req.user.key
  key = "#{(req.body or {}).plan or ''}"
  db.query "select * from plan where key = $1", [key]
    .then (r = {}) ->
      if !(plan = r.[]rows.0) => return lderror.reject 400
      live owner .then (existing) ->
        if existing => return lderror.reject 1014
        period = this-period!
        db.query """
        insert into subscription (owner, plan, state, period)
        values ($1, $2, 'active', $3) returning key
        """, [owner, plan.key, period]
          .then (r2 = {}) ->
            ref = (r2.[]rows.0 or {}).key
            # cap comes from caps[plan.key] - see backend/suite/credit.ls
            credit!fill-sub owner, plan.key, {ref, period}
              .then -> live owner
              .then (subscription) ->
                credit!balance owner .then (balance) -> res.send {subscription, balance}

api.post \/demo/subscription/cancel, aux.signedin, (req, res) ->
  owner = req.user.key
  live owner .then (sub) ->
    if !sub => return lderror.reject 404
    if sub.state != \active => return lderror.reject 400
    # canceled, not expired: the period is paid for and stays spendable. the
    # credits are untouched here on purpose - is-pro still returns true.
    db.query """
    update subscription set state = 'canceled', modifiedtime = now() where key = $1
    """, [sub.key]
      .then -> live owner
      .then (subscription) ->
        credit!balance owner .then (balance) -> res.send {subscription, balance}

# the billing cron, as a button. rolls one period forward:
#   active    -> next period, top the pool back up to the plan's cap
#   canceled  -> expired, and the pool is zeroed
#   suspended -> the period moves, nothing is granted. an unpaid subscription
#                must not accrue credits, and what it already holds stays put:
#                is-pro is what makes that unspendable, not a deduction.
api.post \/demo/subscription/advance, aux.signedin, (req, res) ->
  owner = req.user.key
  live owner .then (sub) ->
    if !sub => return lderror.reject 404
    p = if sub.state == \suspended
      db.query """
      update subscription set period = $2, modifiedtime = now() where key = $1
      """, [sub.key, next-period(sub.period, sub.frequency)]
    else if sub.state == \canceled
      db.query """
      update subscription set state = 'expired', modifiedtime = now() where key = $1
      """, [sub.key]
        .then -> credit!zero-sub owner, {ref: sub.key}
    else
      period = next-period sub.period, sub.frequency
      db.query """
      update subscription set period = $2, modifiedtime = now() where key = $1
      """, [sub.key, period]
        .then -> credit!fill-sub owner, sub.plan, {ref: sub.key, period}
    p.then -> live owner
      .then (subscription) ->
        credit!balance owner .then (balance) -> res.send {subscription, balance}

# staff moves a subscription between the three live states. `expired` is not
# offered: that is the end of the line and only `advance` produces it, together
# with the zero-sub that goes with it.
#
# none of these touch the credits. suspending withdraws the entitlement through
# is-pro and leaves the balance exactly where it was, so resuming restores it
# without a re-grant - which is the whole reason the module gates instead of
# zeroing. see doc/web/README.md.
STAFF_STATES = <[active canceled suspended]>

api.post \/staff/subscription, aux.signedin, aux.is-admin, (req, res) ->
  {owner, state} = req.body or {}
  if !owner or isNaN(+owner) => return lderror.reject 400
  if !(state in STAFF_STATES) => return lderror.reject 400
  owner = +owner
  live owner .then (sub) ->
    if !sub => return lderror.reject 404
    db.query """
    update subscription set state = $2, modifiedtime = now() where key = $1
    """, [sub.key, state]
      .then -> db.audit {req, action: '@staff/subscription:state', option: {owner, state}}
      .then -> live owner
      .then (subscription) ->
        credit!balance owner .then (balance) -> res.send {subscription, balance}

api.get \/staff/subscription/:key, aux.signedin, aux.is-admin, (req, res) ->
  owner = +req.params.key
  if isNaN(owner) or owner <= 0 => return lderror.reject 400
  live owner .then (subscription) -> res.send {subscription}
