# Billing

How this site turns money into credits, and back again. The credits themselves
are `@servebase/credit`'s business — see that module's README for the ledger,
the two pools and the primitives. This document covers what belongs to the site:
the `plan`, `subscription` and `purchase` tables, and the flows that write them.

Schema lives in `config/web/db/`, routes in `backend/suite/`.


## Two ways to get credits

|  | subscription | purchase |
|--|--------------|----------|
| bought as | a recurring plan | a one-off top-up |
| site table | `plan` + `subscription` | `purchase` |
| credit pool | `subscription` | `purchase` |
| granted by | `fill-sub`, once per period | `grant`, once per payment |
| spent | first | second, oldest grant first |
| ends by | the plan ending | a date, or never |

`consume` spends the subscription pool first, so the perishable credits drain
before the paid-outright ones.


## Plans and subscriptions

    plan          key, name, frequency, price, currency, credits, ordering
    subscription  key, owner, plan, state, period

One subscription per user, enforced by a partial unique index on everything that
is not `expired`. There is no upgrade flow: cancel, then subscribe again.

`credits` on the plan is the cap granted at the start of each period. The demo
loads these into the module's `caps` at boot, keyed by plan:

    caps = {month: 300, year: 3000}
    backend.db.query "select key, credits from plan"
      .then (r) -> r.rows.map -> caps[it.key] = it.credits

`fill-sub(owner, name)` only looks up `caps[name]`, so passing the plan key works
and two monthly plans can grant different amounts — which a `{month, year}` map
cannot express. Loading from the table is what keeps the price list and the grant
size from drifting apart.


### States

| state | is-pro | credits | who sets it |
|-------|--------|---------|-------------|
| `active` | yes | — | subscribing, or staff |
| `canceled` | yes | — | the user cancelling, or staff |
| `suspended` | **no** | **untouched** | staff |
| `expired` | no | zeroed | `advance`, and only `advance` |

`active` / `canceled` / `suspended` are freely interchangeable from the staff
console. `expired` is terminal.

`is-pro` is injected in `backend/suite/credit.ls` as "has a subscription in state
`active` or `canceled`". It is the gate on the subscription pool: when it returns
false the balance is still there and still counted, it simply cannot be spent.

**`canceled` is not `expired`.** The period is paid for and keeps running; only
renewal stops. Zeroing on cancel would be taking back something already sold.

**`suspended` withdraws entitlement without touching the balance**, and this is
the single most useful thing about gating. The obvious alternative — zero the
pool on suspend, re-grant on resume — is not idempotent: a suspension that flaps,
or a cron that re-runs, either loses credits or mints them. Flipping a gate is
idempotent however many times it happens, and suspend → resume writes nothing to
the ledger at all.


### The period roll

`POST /api/demo/subscription/advance` is a billing cron as a button:

| state | what happens |
|-------|--------------|
| `active` | period moves on, pool topped back up to the plan's cap |
| `canceled` | becomes `expired`, pool zeroed via `zero-sub` |
| `suspended` | period moves on, **nothing granted** |

An unpaid subscription must not accrue credits, and what it already holds stays
put — `is-pro` is what makes that unspendable, not a deduction.

`fill-sub` takes the subscription row key and the period, and the module has a
partial unique index on `(owner, ref_type, ref_id, period)` for `grant` rows. A
cron that re-runs within the same period is a no-op enforced by the database, not
by a check in application code.

Note that `fill-sub` tops the pool *up to* the cap, so an unspent remainder
carries into the next period. If a site wants each period's allowance to be
use-it-or-lose-it, that is a change to what the roll does — expire the remainder,
then grant the full cap — not a new mechanism.


## Purchases

    purchase  key, owner, gateway, amount, refunded, price, currency

`POST /api/demo/topup` writes the purchase row and grants the credits **in one
transaction**, with the credits carrying `(ref_type: 'purchase', ref_id: <key>)`:

    db.transaction (tx) ->
      tx.query "insert into purchase (...) returning key", [...]
        .then (r) ->
          credit.grant {owner, pool: \purchase, amount, action: \purchase,
                        ref-type: \purchase, ref-id: r.rows.0.key, tx}

A ref pointing at a purchase that failed to insert would be worse than no ref at
all; the whole value of the pair is that it always resolves. There is no foreign
key — the credit module has no idea what tables exist in the database it is
installed into — so the guarantee has to come from writing both together.

This is a stand-in for a payment gateway. A real site reaches this code from a
verified callback, never from a button, because only the gateway knows whether
the money moved. The dialog on `/credit` says so in large letters.


## Refunds

`POST /api/staff/credit/refund` wraps `credit.refund` and updates
`purchase.refunded` in the same transaction. The module deliberately does not
route this: the claw-back and the site's own bookkeeping have to land together,
which means one transaction, which means the host owns the route.

The refund comes out of **that purchase's own grant**, never FIFO across the
others. A negative `adjust` would take it from whichever grant is oldest:

    buy A(100), buy B(100)     purchase = 200
    spend 100                  FIFO drains A;  A = 0, B = 100
    refund A with adjust -100  takes it from B!  B = 0
    refund B                   insufficient_balance, though B was never spent

and the ledger would record two `adjust` rows with no link to what was reversed.
Use a negative `adjust` only for a correction that reverses no particular
purchase.

A refund resolves rather than rejecting when the credits are already spent —
`{requested: 100, refunded: 85, shortfall: 15}`. The shortfall is a fact about
the credits, not about the money; whether to return the payment anyway is a
decision this site makes, not the ledger.


## Expiry

Purchased credits expire `GRANT_TTL` days after purchase — 365 in
`backend/suite/credit.ls`. The top-up form can override it per purchase, or opt
out entirely, because the module takes the override per grant.

Subscription credits have no expiry date and do not need one:

 - a subscription period ends on an **event that already runs code** — the roll
   calls `fill-sub`, the end calls `zero-sub`. There is nothing to go looking
   for.
 - a purchased credit expires when **nothing at all is happening**. That is
   exactly the case that needs a sweep.

So expiry is `credit.expire-grants`, normally run from cron;
`POST /api/staff/credit/expire` runs it, optionally for one owner. **Until it
runs, a grant past its date still shows its balance** — the staff purchase list
says `expired` next to `paid / 100 left`, which looks wrong for a moment and is
exactly right: a date passing is not an event.

Refunding an expired purchase needs no special case. `remaining` is 0, so the
refund claws back 0 and reports the full shortfall.


## Reading one purchase end to end

Every movement against a purchase carries the same `(ref_type, ref_id)`, so its
whole life is one query. `ref_id` is text, so cast the host key rather than the
other way round:

    select p.key, p.amount,
           coalesce(-sum(l.delta) filter (where l.action = 'refund'), 0)  as refunded,
           coalesce(-sum(l.delta) filter (where l.action = 'expire'), 0)  as expired,
           coalesce(-sum(l.delta) filter (where l.action = 'consume'), 0) as consumed,
           g.remaining
    from purchase p
    left join credit_log   l on l.ref_type = 'purchase' and l.ref_id = p.key::text
    left join credit_grant g on g.ref_type = 'purchase' and g.ref_id = p.key::text
    where p.owner = $1
    group by p.key, p.amount, g.remaining

     key | amount | refunded | expired | consumed | remaining
       1 |    100 |       85 |       0 |        0 |         0
       2 |    100 |        0 |     100 |        0 |         0

Nothing cascades: deleting a purchase leaves its ledger rows pointing at nothing.
That is usually right for an append-only ledger, but it does mean this site is
responsible for not deleting rows it still refers to.


## Routes

Site-owned, in `backend/suite/`:

| method | path | who |
|--------|------|-----|
| GET | `/api/demo/plan` | anyone |
| GET | `/api/demo/subscription` | signed in |
| POST | `/api/demo/subscription` | signed in — `{plan}` |
| POST | `/api/demo/subscription/cancel` | signed in |
| POST | `/api/demo/subscription/advance` | signed in — the cron stand-in |
| GET | `/api/demo/price` | anyone |
| POST | `/api/demo/job` | signed in — consumes credit |
| POST | `/api/demo/topup` | signed in — `{amount, ttl}` |
| GET | `/api/staff/subscription/:key` | staff |
| POST | `/api/staff/subscription` | staff — `{owner, state}` |
| GET | `/api/staff/credit/purchase/:key` | staff |
| POST | `/api/staff/credit/refund` | staff — `{owner, purchase, amount, memo}` |
| POST | `/api/staff/credit/refund-sub` | staff — `{owner, amount, memo}` |
| POST | `/api/staff/credit/sub` | staff — `{owner, action, frequency}` |
| POST | `/api/staff/credit/expire` | staff — `{owner}` |

Module-owned routes ( balance, ledger, staff adjust, grant list, reconcile ) are
listed in `@servebase/credit`'s README.
