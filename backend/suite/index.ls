/*
 * backend routes for the `web` demo site ( frontend/web ).
 *
 * loaded by backend/engine/index.ls, which requires every backend/<name>
 * directory. the guard below keeps these routes off any other site built on
 * this repo - same pattern as backend/base.
 */
(backend) <- (->module.exports = it)  _
{config} = backend
if config.base != \web => return

require! <[fs path]>

fs.readdir-sync __dirname
  .filter -> !/^index\./.exec(it)
  .filter -> !/^\./.exec(it)
  .map -> path.join(__dirname, it)
  .filter -> /\.(ls|js)$/.exec(it) or fs.stat-sync(it).is-directory!
  .map -> require(it) backend
