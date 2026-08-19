# staff account management api.
#
# every route is guarded by `aux.is-admin` ( users.staff == 1 ). staff may act
# on each other - this is a demo site, and a rule that staff are untouchable
# leaves them manageable only by hand-written SQL. the batch endpoint still
# refuses the caller's own account, so a mis-click on "select all" cannot lock
# the operator out of the console they are standing in.

require! <[lderror re2js curegex @servebase/backend/aux]>
(backend) <- (->module.exports = it)  _
{db, session, route: {api}} = backend

re-email = curegex.tw.get \email, re2js.RE2JS
is-email = -> !!re-email.exec(it)

# whitelist: these land in the sql text, so they must never come from the client
# unchecked. `verified` sorts jsonb null-first, which reads as "unverified first".
SORTABLE = <[key username displayname createdtime verified]>
ACTIONS = <[verify unverify logout delete password-reset]>

gen-password = -> Math.random!toString(36).substring(2) + Math.random!toString(36).substring(2, 6)

api.post \/staff/user/lookup, aux.signedin, aux.is-admin, (req, res) ->
  body = req.body or {}
  query = "#{body.query or ''}".trim!substring 0, 32
  limit = if isNaN(+body.limit) => 50 else (+body.limit >? 1 <? 200)
  offset = if isNaN(+body.offset) => 0 else (+body.offset >? 0)
  sort = if body.sort in SORTABLE => body.sort else \key
  desc = if body.desc => \desc else \asc

  params = []
  cond = "where deleted is not true"
  if query =>
    # separate params: the ilike pattern is wrapped in %, an exact key match
    # against that pattern would never hit.
    params.push "%#query%", query
    cond += " and (displayname ilike $1 or username ilike $1 or key::text = $2)"

  Promise.all [
    db.query """
    select key, username, displayname, verified, staff, createdtime, lastactive
    from users #cond
    order by #sort #desc, key asc
    limit $#{params.length + 1} offset $#{params.length + 2}
    """, params ++ [limit, offset]
    db.query "select count(key) as count from users #cond", params
  ]
    .then ([r, c]) ->
      res.send {
        list: r.[]rows, count: +(c.[]rows.0 or {}).count or 0, limit, offset
      }

api.post \/staff/user, aux.signedin, aux.is-admin, (req, res) ->
  {username, displayname, verified} = req.body or {}
  username = "#{username or ''}".trim!toLowerCase!
  if !is-email username => return lderror.reject 1015
  # returned to the operator once, so an account can be handed over immediately.
  password = "#{(req.body or {}).password or ''}" or gen-password!
  db.user-store.create {
    username, password, method: \local
    detail: {displayname: "#{displayname or ''}".trim!}
    # force: staff creates accounts regardless of the site's signup policy
    # ( invite-only, closed ). renewpw makes the handed-over password one-shot.
    force: true, config: {authinfo: {renewpw: true}}
  }
    .then (user) ->
      if !verified => return user
      backend.auth.user.set-verified {key: user.key, verified: true} .then -> user
    .then (user) ->
      db.audit {req, action: '@staff/user:create', option: {user: {key: user.key}}}
        .then -> res.send {key: user.key, username: user.username, password}

# batch action over selected accounts. always reports per-key results instead of
# failing the whole request, so a partial failure is visible rather than silent.
api.post \/staff/user/update, aux.signedin, aux.is-admin, (req, res) ->
  {keys, action} = req.body or {}
  if !Array.isArray keys => return lderror.reject 400
  if !(action in ACTIONS) => return lderror.reject 400
  keys = Array.from(new Set(keys.map(-> +it).filter -> it and !isNaN it))
  if !keys.length => return lderror.reject 400

  ps = keys.map (key) ->
    o = {key, result: \ok}
    db.query "select key, username, staff from users where key = $1 and deleted is not true", [key]
      .then (r = {}) ->
        if !(user = r.[]rows.0) => return o.result = \not-found
        o.username = user.username
        if user.key == req.user.key => return o.result = \self
        switch action
        | \verify => backend.auth.user.set-verified {key, verified: true}
        | \unverify => backend.auth.user.set-verified {key, verified: false}
        | \logout => session.delete {user: key}
        | \delete => backend.auth.user.delete {key}
        | \password-reset =>
          o.password = gen-password!
          db.user-store.hashing o.password
            .then (hash) ->
              db.query """
              update users set (password, method) = ($2, 'local'),
                config = jsonb_set(
                  coalesce(config, '{}'::jsonb), '{authinfo}',
                  coalesce(config->'authinfo', '{}'::jsonb) || '{"renewpw": true}'::jsonb, true
                )
              where key = $1
              """, [key, hash]
            # a fresh password must invalidate live sessions, otherwise the old
            # holder keeps their access.
            .then -> session.delete {user: key}
      .catch (e) ->
        backend.log.error {err: e}, "staff user update failed for #key"
        o.result = \server-error
        delete o.password
      .then -> o
  Promise.all ps
    .then (list) ->
      db.audit {req, action: "@staff/user:#action", new: {users: list.map -> it{key, result}}}
        .then -> res.send {list}
