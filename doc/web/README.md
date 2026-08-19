# Demo Site (`web`)

A small site built on servebase that exercises two things end to end: staff
account management, and credits.

 - frontend: `frontend/web`
 - backend: `backend/suite`
 - schema: `config/web/db/*.sql`

`backend/suite` guards itself with `if config.base != \web => return`, the same
way `backend/base` does, so the routes only load for this site.


## Setup

 1. Point a private config at this site. In `config/private/<name>.ls`, set:

        base: 'web'

    `base` selects both `frontend/web` and the `backend/suite` guard, and makes
    `tool/base/database/init.ls` run `config/web/db/*.sql`.

 2. Install. The credit module is consumed from the sibling repo:

        npm install                       # root; pulls @servebase/credit
        cd frontend/web && npm install    # frontend deps; postinstall runs fedep

    `package.json` takes the credit module straight from git
    ( `github:servebase/credit#master` ). To work on it alongside this site:

        cd ../credit && npm link
        cd ../suite  && npm link @servebase/credit

    A later `npm install` replaces the link with the git copy again, so re-link
    when that happens.

 3. Create the database:

        npm run docker-db                 # if you need a local postgres
        npx lsc tool/base/database/init.ls

 4. Run:

        ./start -c <name>

 5. Make yourself staff. There is no bootstrap flow for this — sign up through
    the site, then:

        update users set staff = 1 where username = 'you@example.com';

    Sign out and back in; `req.user.staff` comes from the session.


## Pages

| path | who | what |
|------|-----|------|
| `/` | anyone | landing; links appear as the auth state allows |
| `/credit` | signed in | subscription, balance, spend, top up, own ledger |
| `/staff/user` | staff | account list, batch actions, per-account credit |


## Subscription

The demo carries a `plan` table ( Basic / Pro / Pro Yearly ) and one
`subscription` row per user, for one reason: without a plan there is nothing for
`is-pro` to gate on, the subscription pool is always spendable, and the whole
point of splitting the pools is invisible.

`backend/suite/credit.ls` injects `is-pro` as "has a subscription in state
`active` or `canceled`". Four states, and what each does to the credits:

| state | is-pro | credits | meaning |
|-------|--------|---------|---------|
| `active` | yes | — | paying |
| `canceled` | yes | — | will not renew; the period already paid for still runs |
| `suspended` | **no** | **untouched** | entitlement withdrawn for now |
| `expired` | no | zeroed | over, and terminal |

`active` / `canceled` / `suspended` are freely interchangeable from the staff
console ( `POST /api/staff/subscription` ). Only `advance` produces `expired`.

**`suspended` is the interesting one.** It withdraws the entitlement without
touching the balance: the credits stay on record and unspendable, and switching
back to `active` restores them exactly, writing nothing to the ledger. That is
the whole reason the module gates instead of zeroing — zero-on-suspend and
re-grant-on-resume loses or duplicates credits whenever a suspension flaps or a
cron re-runs, whereas flipping a gate is idempotent no matter how many times it
happens.

Advancing a period follows the same logic: an active subscription is topped back
up to the cap, a canceled one becomes `expired` and is zeroed, and a suspended
one only moves its period — an unpaid subscription must not accrue credits, and
what it already holds stays put.

Caps are keyed by **plan**, not by billing frequency. `fill-sub(owner, name)`
only looks up `caps[name]`, so passing the plan key works and two monthly plans
can grant different amounts — which `{month, year}` cannot express. The caps are
loaded from the `plan` table at boot so the price list and the grant size cannot
drift apart.

`POST /api/demo/subscription/advance` is the billing cron as a button: an active
subscription rolls to the next period and tops the pool back to the cap; a
canceled one becomes `expired` and its pool is zeroed.

The payment dialog on `/credit` is an `ldcover` with a disabled, decorative card
field and a banner saying so. It exists to show the shape of the flow — a real
site never reaches its subscribe endpoint from a button, because only the gateway
knows whether the money moved.


## Expiry

Purchased credits expire 365 days after purchase ( `GRANT_TTL` in
`backend/suite/credit.ls` ). The top-up form lets one purchase override that —
in a year, in 30 days, immediately, or never — because the module takes the
override per grant and the demo is more useful showing all four.

Subscription credits have no expiry date and do not need one. The asymmetry is
the point:

 - a subscription period ends on an **event that already runs code** —
   `fill-sub` rolls it, `zero-sub` ends it — so there is nothing to go looking
   for.
 - a purchased credit expires when **nothing at all is happening**, which is
   exactly the case that needs a sweep.

So expiry is a sweep, `credit.expire-grants`, normally run from cron. Until it
runs, a grant past its date still shows its remaining balance — the staff
purchase list says `expired` next to `paid / 100 left`, which looks wrong for a
moment and is exactly right: the date passing is not an event.

`POST /api/staff/credit/expire` runs it, optionally for one owner — the button
on the staff credit panel. One transaction per owner, one `expire` ledger row per
grant, each still pointing at the purchase it came from, so a purchase reads end
to end:

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

Refunding an expired purchase is not a special case: `remaining` is 0, so
`refund` claws back 0 and reports the shortfall. Whether to return the money
anyway is a decision the ledger does not make.


## API

Staff account management — `backend/suite/staff.ls`, all guarded by
`aux.signedin` + `aux.is-admin` (`users.staff == 1`):

 - `POST /api/staff/user/lookup` — `{query, limit, offset, sort, desc}` →
   `{list, count, limit, offset}`. `sort` is whitelisted before it reaches SQL.
 - `POST /api/staff/user` — `{username, displayname, password, verified}`.
   Creates with `force: true` (ignores the site's signup policy) and
   `authinfo.renewpw` so the handed-over password must be changed on first login.
   The password is returned once.
 - `POST /api/staff/user/update` — `{keys, action}` where action is one of
   `verify unverify logout delete password-reset`. Returns a per-key result list
   instead of failing wholesale, and refuses staff accounts and the caller's own
   account.

Demo feature and top-up — `backend/suite/credit.ls`:

 - `GET /api/demo/price` — the price list, so the page and the server cannot
   disagree about what a job costs.
 - `POST /api/demo/job` — `{name}`; consumes credit and inserts the `demo_job`
   row in the same transaction.
 - `GET /api/demo/job` — recent jobs.
 - `POST /api/demo/topup` — `{amount}`; stands in for a payment callback. There
   is no gateway here, so it is capped and clearly marked demo-only.

Credit itself is mounted from the module — see the table in
`@servebase/credit`'s README for `/api/credit` and `/api/credit/staff/*`.


## Notes on the credit module

`@servebase/credit` was carved out of an application that already had `purchase`
and `bill_agreement` tables, and it still referenced them: `credit_grant` had a
foreign key to `purchase(key)`, and the default `is-pro` queried
`bill_agreement`. Neither table exists in a plain servebase database, so the
module could not actually be installed on one. As of 0.2.0:

 - host references are loose `(ref_type, ref_id)` pairs with no foreign key.
 - `is-pro` defaults to "spendable" and is meant to be injected; this site injects
   it against its own `subscription` table ( see above ).
 - subscription grants record `sub-ref-type` rather than a hardcoded table name.

Two things worth knowing when reading the code:

 - The `subscription` / `purchase` split is a policy decision baked into a check
   constraint. A site that only ever needs one balance simply never calls
   `fill-sub`, and the purchase pool behaves as a plain balance.
 - `consume(work)` runs `work` inside the transaction holding the balance locks.
   That is what makes "charge and record" atomic, and also why `work` must stay
   short and free of external side effects.

The schema is copied into `config/web/db/010-credit.sql` rather than read from
`node_modules`, because `tool/base/database/init.ls` only scans
`config/<base>/db`. Re-copy it after upgrading the module.
