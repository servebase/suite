# credit for the demo site.
#
# mounts @servebase/credit's own routes ( balance, ledger, staff adjust ) and
# adds the two things that are necessarily application specific: what a credit
# buys, and how one is bought.

require! <[lderror @servebase/backend/aux]>
credit-route = require \@servebase/credit/route

(backend) <- (->module.exports = it)  _
{db, route: {api}} = backend

# caps are keyed by plan, not by billing frequency: `fill-sub(owner, name)` only
# looks up `caps[name]`, and two monthly plans granting different amounts is the
# ordinary case, which a {month, year} map cannot express. loaded from the plan
# table at boot so the price list and the grant size cannot drift apart.
caps = {month: 300, year: 3000}
backend.db.query "select key, credits from plan"
  .then (r = {}) -> r.[]rows.map -> caps[it.key] = it.credits
  .catch (e) -> backend.log.error {err: e}, "credit: failed to load plan caps"

# the gate on the subscription pool. a canceled subscription keeps its credits
# spendable until the period it already paid for runs out - which is exactly why
# the module gates rather than zeroing on cancel: nothing is lost or re-granted
# when someone cancels and changes their mind.
is-pro = (owner, tx) ->
  (tx or backend.db).query """
  select key from subscription
  where owner = $1 and state in ('active', 'canceled')
  limit 1
  """, [owner]
    .then (r = {}) -> !!r.[]rows.0

# purchased credits expire a year after they are bought unless a grant says
# otherwise. a site-wide default is the only honest place for this: it is a term
# of sale, not a per-call decision.
GRANT_TTL = 365

# guards are required: the module has no standing to decide who counts as staff
# here, and four of its five staff endpoints never touch `req.user`, so a
# missing guard would serve every user's ledger rather than failing.
credit = credit-route backend, {
  caps, is-pro, sub-ref-type: \subscription, grant-ttl: GRANT_TTL
  guard: {generic: aux.signedin, staff: [aux.signedin, aux.is-admin]}
}

# priced features. the price list is served to the frontend so the two never
# disagree about what a job costs.
PRICE = {basic: 5, deluxe: 25}
TOPUP_MAX = 500

api.get \/demo/price, (req, res) ->
  res.send {price: PRICE, topupMax: TOPUP_MAX, grantTtl: GRANT_TTL}

api.post \/demo/job, aux.signedin, (req, res) ->
  name = "#{(req.body or {}).name or ''}"
  if !(name in Object.keys PRICE) => return lderror.reject 400
  amount = PRICE[name]
  owner = req.user.key
  work = (tx) ->
    tx.query """
    insert into demo_job (owner, name, cost) values ($1, $2, $3) returning key
    """, [owner, name, amount]
      .then (r = {}) -> {ref: (r.[]rows.0 or {}).key}
  p = credit.consume {owner, amount, source-type: "job:#name", ref-type: \demo_job}, work
  p.then (job) ->
    credit.balance owner .then (balance) -> res.send {job: job.ref, cost: amount, balance}

api.get \/demo/job, aux.signedin, (req, res) ->
  db.query """
  select * from demo_job where owner = $1 order by key desc limit 20
  """, [req.user.key]
    .then (r = {}) -> res.send {list: r.[]rows}

# demo top-up. a real site would only reach `credit.grant` from a verified
# payment callback - here there is no gateway, so this stands in for one and is
# capped to keep it obviously a demo.
#
# the purchase row and the credits it buys are written in one transaction, and
# the credits carry (ref_type='purchase', ref_id=<key>). a ref pointing at a
# purchase that failed to insert would be worse than no ref at all: the whole
# point of the pair is that it always resolves.
api.post \/demo/topup, aux.signedin, (req, res) ->
  body = req.body or {}
  amount = Math.round +body.amount
  if isNaN(amount) or amount <= 0 or amount > TOPUP_MAX => return lderror.reject 400
  owner = req.user.key
  price = (amount / (credit.conf.credits-per-usd or 50)).toFixed 2
  # ttl absent -> the site default; explicit null -> never expires; a number ->
  # that many days. the demo exposes all three so the difference is visible.
  ttl = body.ttl
  exp = if ttl == void => {}
  else if ttl? and !isNaN(+ttl) => {ttl: +ttl}
  else {ttl: null}
  p = db.transaction (tx) ->
    tx.query """
    insert into purchase (owner, gateway, amount, price, currency)
    values ($1, 'demo', $2, $3, 'USD') returning key
    """, [owner, amount, price]
      .then (r = {}) ->
        if !(key = (r.[]rows.0 or {}).key) => return lderror.reject 500
        credit.grant ({
          owner, pool: \purchase, amount, action: \purchase
          source-type: \demo-topup, ref-type: \purchase, ref-id: key, tx
        } <<< exp)
          .then -> key
  p.then (key) ->
    credit.balance owner .then (balance) -> res.send {purchase: key, balance}


# subscription pool controls for staff.
#
# these live here rather than in the module: when the subscription pool is
# refilled is plan policy, normally driven by a billing cron. this demo has no
# plans, so staff drives it by hand - which is also the only way to see the pool
# split and the is-pro gate actually do something.
api.post \/staff/credit/sub, aux.signedin, aux.is-admin, (req, res) ->
  {owner, action, frequency} = req.body or {}
  if !owner or isNaN(+owner) => return lderror.reject 400
  owner = +owner
  p = if action == \fill => credit.fill-sub owner, (if frequency == \year => \year else \month)
  else if action == \zero => credit.zero-sub owner
  else lderror.reject 400
  p.then (ret) -> credit.balance owner .then (balance) -> res.send {balance, result: ret}

# purchases of one user, with what the credit module still has open against each.
# the join is the whole point of the loose ref: `ref_id` is text, so the host key
# is cast rather than the other way round.
api.get \/staff/credit/purchase/:key, aux.signedin, aux.is-admin, (req, res) ->
  owner = +req.params.key
  if isNaN(owner) or owner <= 0 => return lderror.reject 400
  db.query """
  select p.*, coalesce(g.remaining, 0) as remaining, g.expiretime,
         (g.expiretime is not null and g.expiretime <= now()) as due
  from purchase p
  left join credit_grant g
    on g.ref_type = 'purchase' and g.ref_id = p.key::text and g.owner = p.owner
  where p.owner = $1
  order by p.key desc limit 50
  """, [owner]
    .then (r = {}) -> res.send {list: r.[]rows}

# staff refund of a purchase.
#
# wrapping `credit.refund` rather than routing it from the module: the claw-back
# and this site's own bookkeeping ( purchase.refunded ) have to land together,
# which means one transaction, which means the host has to own the route.
api.post \/staff/credit/refund, aux.signedin, aux.is-admin, (req, res) ->
  {owner, purchase, amount, memo} = req.body or {}
  if !owner or isNaN(+owner) or !purchase or isNaN(+purchase) => return lderror.reject 400
  if !"#{memo or ''}".trim! => return lderror.reject 400, {reason: \memo_required}
  owner = +owner
  p = db.transaction (tx) ->
    credit.refund {
      owner, ref-type: \purchase, ref-id: +purchase, amount, memo
      source-type: \staff, by-user: req.user.key, tx
    }
      .then (ret) ->
        if !ret.refunded => return ret
        tx.query """
        update purchase set refunded = refunded + $2, modifiedtime = now()
        where key = $1 and owner = $3
        """, [+purchase, ret.refunded, owner]
          .then -> ret
  p.then (ret) ->
    credit.balance owner .then (balance) -> res.send (ret <<< {balance})

# staff refund of the current subscription period. `consumed` in the reply is
# what an all-or-nothing policy would refuse on; this demo refunds the remainder.
api.post \/staff/credit/refund-sub, aux.signedin, aux.is-admin, (req, res) ->
  {owner, amount, memo} = req.body or {}
  if !owner or isNaN(+owner) => return lderror.reject 400
  if !"#{memo or ''}".trim! => return lderror.reject 400, {reason: \memo_required}
  owner = +owner
  credit.refund-sub {owner, amount, memo, source-type: \staff, by-user: req.user.key}
    .then (ret) ->
      credit.balance owner .then (balance) -> res.send (ret <<< {balance})

# the expiry sweep as a button. a real deployment runs `credit.expire-grants`
# from cron; there is nothing to react to when a credit expires, so somebody has
# to go looking - which is exactly what makes this different from the
# subscription pool, whose period ends on an event that already runs code.
api.post \/staff/credit/expire, aux.signedin, aux.is-admin, (req, res) ->
  owner = (req.body or {}).owner
  owner = if owner? and !isNaN(+owner) => +owner else null
  credit.expire-grants {owner}
    .then (ret) ->
      if !owner => return res.send ret
      credit.balance owner .then (balance) -> res.send (ret <<< {balance})
