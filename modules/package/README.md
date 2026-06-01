# EJS Package Module

`modules/package` installs audited unpacked `.ejspkg` directories into an
`EJSContext`.

The Apple MVP keeps npm-specific work outside the runtime. The installer reads
`ejs-package.json`, verifies the approval manifest or approved hashes, checks
package/module hashes, rejects unsupported capabilities and unsafe paths, then
registers a bounded in-memory module source table with the core loader.

It does not run package scripts, read arbitrary package directories, download
dependencies, or grant host providers to converted packages.
