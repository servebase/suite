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


## Billing

Plans, subscriptions, purchases, refunds and expiry are documented on their own
in [billing.md](billing.md) — including why the two credit pools are not
symmetric and why suspending a plan deliberately touches no credits.

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

Credit, plans and purchases have their own routes — see
[billing.md](billing.md#routes) for the full table, and `@servebase/credit`'s
README for the module-owned ones.


## Notes on the credit module

`@servebase/credit` was carved out of an application that already had `purchase`
and `bill_agreement` tables and still referenced them, so it could not be
installed on a plain servebase database at all. Fixing that is what the module's
0.2.0 was. The reasoning behind its current shape — three tables, two pools that
are deliberately not symmetric, gating instead of zeroing — is in that module's
README under **Design notes**; this site is just its first caller.

One thing that is genuinely local: the schema is **copied** into
`config/web/db/010-credit.sql` rather than read from `node_modules`, because
`tool/base/database/init.ls` only scans `config/<base>/db`. Re-copy it after
upgrading the module, and apply the matching file from the module's `migrate/`.
