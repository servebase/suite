# page routes for the demo site. api routes live next to the feature they serve.
require! <[@servebase/backend/aux @servebase/backend/throttle]>
(backend) <- (->module.exports = it)  _
{route: {app}} = backend

app.get \/, throttle.kit.generic, (req, res) -> res.render \index.pug

# both pages fetch everything they show over the api, so nothing is passed in
# here; the guards only decide who gets to see the shell at all.
app.get \/credit, aux.signedin, (req, res) -> res.render \credit/index.pug

app.get \/staff/user, aux.signedin, aux.is-admin, (req, res) -> res.render \staff/user.pug
