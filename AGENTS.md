# Logseq Linux Client + Self-Hosted Stack

## Goal

Package Logseq (the new DB-graph version, rev 2.0.1) for Linux with Nix at
`./logseq-flake/`, and extend that to a fully self-hostable stack: web
app, sync server, publish service, Android app — each with its own
identity provider (self-hosted Keycloak) and sync/publish endpoints
configurable at build time, so none of it is hardwired to upstream's
Cognito pool or `logseq.io`/`logseq.com`.

## Current state (2026-09-29)

All work lives in `./logseq-flake/`, a standalone flake. Its `nixpkgs`/
`flake-parts`/`import-tree` inputs are the tooling; the pinned Logseq source
and its ~10 git-lib dependencies are now flake inputs too (`logseq-src`,
`hsx-src`, ...), each `flake = false` — every one of them is overridable
from the CLI (`--override-input hsx-src github:...`) with no `.nix` edits,
and every hash lives in `flake.lock`, not hand-typed in `_common.nix`. The
flake is imported back into this configuration as the relative path input
`logseq` and re-exported by `./modules/packages/logseq.nix`. Every target
below is verified with `nix build path:.#<target>`, not just evaluated, and
by a check in `./logseq-flake/modules/checks.nix` (`nix flake check`):

|Check|What it proves|
|-|-|
|`sync`|VM: Keycloak realm + sync server. `/health` public, `/graphs` 401 without a token and **200 with one the local realm minted** — the self-hosted-IdP claim, proven. Also asserts the *client* side of the same realm's contract: the id token carries `exp`/`sub`/`email`/`preferred_username` (no `cognito:username` mapper: both patches fall back to it), the realm's discovery document advertises a device endpoint, and the refresh grant works at the `token_endpoint` it names (both what the patched client relies on)|
|`login`|VM, same realm: the **stock** web app package, given `oidcIssuer` and endpoints only at runtime (`services.logseq-webapp.clientConfig`), signs in **through its own UI** in headless Chromium (driven over the DevTools protocol by a 10-line node script). It reads the realm's discovery document and starts the device flow cross-origin, completes Keycloak's device/login/consent pages, **refreshes at the discovered token endpoint** (asserted from Keycloak's own `REFRESH_TOKEN` events), and then the sync server receives an **authenticated `GET /graphs`** (200), which only happens once the `user_info` stub returned a map. Also asserts the stub's CORS preflight|
|`webapp`|VM: nginx serves the bundle, the app entry point loads|
|`desktop`|Launcher executable, bundled CLI runs, `StartupWMClass` matches the wrapper's `--class`, the app ships its baked `js/logseq-config.js` (next to upstream's fallbacks in `main.js`) and the OCaml CLI its substituted literals|
|`publish`|VM: the same node as `sync`, but with the deployment shape the production host uses: a fixed `user` and a nested `dataDir` (`/var/lib/logseq/publish`), which systemd creates owned by that user. The worker runs outside Cloudflare at all (its Durable Object + R2 bindings come from wrangler's local runtime), serves its rendered home page and inlined static assets, `DELETE /pages/:g/:p` is 401 without a token and **404 with one the local realm minted** — past `verify-jwt`, having fetched the realm's JWKS from inside workerd|
|`android`|The APK is a real APK and its web assets carry the baked `js/logseq-config.js` and upstream's fallbacks|
|`containers`|VM running podman: the generic web app image serves unprivileged under `cap_drop=ALL`, `js/sqlite3.wasm` comes back as `application/wasm`, `/login` falls back to `index.html`, and `LOGSEQ_*` variables given to the container come back in its `js/logseq-config.js`|
|`sync-worker`|VM, same realm as `sync`/`publish`: `/health` public, `/graphs` 401 without a token, `/openapi.json` proves the semantic-REST build step actually produced something, a realm-minted token gets a graphs list (past `verify-jwt` and the D1 user upsert `db-sync.patch` fixes). MCP as Claude Code and opencode use it: `/mcp` 401 without a token, the protected-resource metadata at `publicUrl`, auth code + PKCE on both clients' loopback redirects, then with that access token the semantic REST API (scopes, rate limiters) and an MCP `execute` tool call both return the graphs list|
|`webapp-service`|VM: `services.logseq-webapp`'s own dedicated nginx process serves the bundle, `application/wasm` for `sqlite3.wasm`, `text/javascript` for `pdf.mjs`, `/login` falls back to `index.html` — the module wiring, not just the package (that's `webapp`, above)|
|`desktop-module`|Eval-only (no port to knock on, no VM): a throwaway `nixosSystem` with `programs.logseq.enable = true` actually lands `packages.logseq` in `environment.systemPackages` — `nix flake check`'s own module type-check proves the module evaluates, this proves `enable` does something|

|Target|Package|Status|`clientConfig` override|
|-|-|-|-|
|Desktop (Electron)|`packages.logseq`|done|baked in (`.override { clientConfig = {...}; }`): no server to hand it config at runtime|
|Web app (static PWA)|`packages.logseq-webapp`|done|**at runtime**: `LOGSEQ_*` env (image, `nix run`) or the module's `clientConfig`, over optional baked defaults — proven by `checks.login` on the stock package|
|Sync server (Node adapter)|`packages.logseq-sync`|done|n/a — config is already runtime env vars, not build-time patching|
|Sync worker (Cloudflare Worker build)|`packages.logseq-sync-worker`|done|n/a — same runtime-env-var story as sync/publish|
|Android app|`packages.logseq-android`|done|baked in, like desktop; free since Milestone 2's `gradle.fetchDeps` split|
|Publish service|`packages.logseq-publish`|done|n/a — like sync, config is runtime env vars, not build-time patching|
|Container images|`packages.logseq-{webapp,sync,publish}-image`|done|all generic, configured from the environment; the web app's image optionally bakes defaults|
|NixOS service modules|`flake.nixosModules.logseq-{webapp,sync,sync-worker,publish}`|done|`services.logseq-webapp.clientConfig`, at runtime|
|Desktop NixOS module|`flake.nixosModules.logseq`|done|`package` override, same as the underlying package|
|Desktop home-manager module|`flake.homeManagerModules.logseq`|done|`package` override, same as the underlying package|

Every server/webapp target above is also runnable directly, no install step:
`nix run path:.#logseq-{webapp,sync,sync-worker,publish}`. Node-adapter
services (webapp, sync) default to port **8080**; wrangler/workerd-based
services (sync-worker, publish) default to **8787**. These wrappers live in
`modules/apps/*.nix` — a thin layer, not a new packaging mechanism: for
the two servers with a `*_DATA_DIR` default of `/var/lib/...` (unwritable
by a non-root `nix run`), the wrapper points it at a scratch `mktemp -d`
instead (only when the caller hasn't already set that env var themselves);
the web app has no binary at all, so its wrapper runs the same runner
(`modules/packages/_webapp-nginx.nix`) the container image and the NixOS
module use: `LOGSEQ_*` variables in, the client's config written, nginx
started (see "Container images" below).

### Desktop client

Fully done: pure (every dependency is a fetcher-shaped FOD — no
`outputHash` on anything that also compiles), configurable identity
provider and sync/publish endpoints via `clientConfig`, the app-picker/
taskbar icon mismatch fixed (`--class=Logseq` in the wrapper for X11, and the desktop file named `logseq.desktop` after the Wayland `app_id`), the
`clojure` package's `getExe` eval warning gone (CLI built from source via
`ocamlPackages` instead of patching a bundle). The Wayland/Vulkan ozone
warning at startup is upstream Chromium noise, not a packaging bug.

`flake.nixosModules.logseq` and `flake.homeManagerModules.logseq` both
expose `programs.logseq` — `enable` + an overridable `package` (default
`self.packages.${system}.logseq`, same re-export pattern every service
module uses, so a custom `clientConfig` build is a `package` override, not
a new option). No port, no `serviceName`, no `user`/`group`: unlike every
other module here this isn't a service, so there's nothing to run as or
listen on — it's `environment.systemPackages`/`home.packages = [
cfg.package ]`, the same shape `programs.firefox` and friends use elsewhere
in NixOS/home-manager. The home-manager module additionally has
`autostart` (`xdg.autostart.entries`, gated — like upstream
`programs.keepassxc`'s own `autostart` — on the *separate*
`xdg.autostart.enable` switch, and the package already ships
`share/applications/logseq.desktop`, so nothing extra needs installing for
this to point at). Verified for real, not just written: evaluated both
modules directly (`nixosSystem`/`homeManagerConfiguration`, not a build) —
confirmed `enable` lands the package in `environment.systemPackages`/
`home.packages`, confirmed `autostart` produces the right
`xdg.autostart.entries` path, and confirmed the `assertions` entry actually
fires when `autostart = true` but `xdg.autostart.enable` is left `false`.
`checks.desktop-module` makes the NixOS half of that permanent; the
home-manager half isn't (see "Boundaries" — pulling in `home-manager` as a
flake input just for one test wasn't judged worth it for what's a
well-trodden nixpkgs pattern).

### Web app (`packages.logseq-webapp`)

Static PWA bundle, no Electron/keytar/CLI. Built via upstream's own `pnpm release-app` script. `index.html` uses relative asset paths, so the output
tree is servable as-is from any static-file root — no special server
config needed (verified with `python -m http.server` + `curl`).

**Configured at runtime, so one build serves every deployment.**
`./modules/packages/self-hosting.patch` makes `frontend/config.cljs` read every
identity and endpoint value from `window.LOGSEQ_CONFIG`, which
`js/logseq-config.js` sets before any bundle loads (upstream's literals stay as
the fallbacks). The build bakes that file from `clientConfig` (default `{}`),
and every server of the web app (image, `nix run`, NixOS module) goes through
one runner that rewrites it at startup from `LOGSEQ_*` variables layered over
the baked values (`_webapp-nginx.nix`). `checks.login` runs the stock package
configured this way. This replaced build-time literal substitution for the app
(the OCaml CLI still uses that), and with it the Docker `--build-arg` front
door (`examples/docker-build/`, `logseq-webapp-docker-image`), which only
existed because the config used to be compiled in.

**One residual gap, not fixed**: a hardcoded
`"https://api.logseq.com/logseq/version"` update-check ping isn't one of the
configurable values. Low priority (not an identity/sync/publish endpoint) but
worth knowing before calling endpoint overriding "complete."

### Sync server (`packages.logseq-sync`)

`deps/db-sync`'s documented plain-Node adapter (not the Cloudflare Worker
build upstream deploys). Config is already runtime env vars
(`COGNITO_ISSUER`, `COGNITO_CLIENT_ID`, `COGNITO_JWKS_URL`, `DB_SYNC_*`) —
no build-time patching needed or possible here, which is *why* this
target has no `clientConfig` parameter at all (there's nothing for it to
do). Verified live: ran the binary with a throwaway data dir and fake
Cognito env vars, curled it — `GET /` → 404, `GET /sync/x` → 401 (auth
enforced), proving the server actually functions.

Getting here needed two nixpkgs-specific fixes, both in project memory:
`npm_config_nodedir=${nodejs}` for `better-sqlite3`'s native build, and a
`fetchzip` splice to work around `fetchPnpmDeps` silently dropping one
npm package (`mldoc`) from its fetched store on every attempt.

### Sync worker (`packages.logseq-sync-worker`)

Done. Same `deps/db-sync` source tree and `package.json`/`pnpm-lock.yaml`
as `packages.logseq-sync` (both now share `_common.nix`'s `pnpmDepsSync`/
`mldocSrc` — one fetch covers both, since it's the same lockfile either
way), but compiles a *different* shadow-cljs build id — `db-sync` (an ESM
Cloudflare Worker module), not `db-sync-node` — and layers three things on
top that the Node adapter doesn't have, all hand-written source files
upstream ships beside the compiled output (`deps/db-sync/worker/entry.mjs`
and its siblings): a semantic REST API with generated OpenAPI docs (needs
one extra build step, `pnpm run build:api-docs`, which shells out to the
`redocly` CLI — already a devDependency in the same lockfile, so no new
fetch), an MCP (Model Context Protocol) endpoint, and ChatGPT "Apps"
integration endpoints.

Storage is D1 + Durable Object + R2, not the SQLite/filesystem
`packages.logseq-sync` uses — **genuinely incompatible with it**, not two
frontends onto one dataset (confirmed against the third-party
`logseq-selfhost` project's own README, which packages both the exact same
way this flake does, and says so explicitly). Production
(`./modules/system/hosts/server/hypervisor/services/logseq.nix` in the
parent configuration) runs this variant, not the plain Node adapter.

Structurally this is much closer to `packages.logseq-publish` (wrangler's
local runtime, same `CLOUDFLARE_INCLUDE_PROCESS_ENV=true`/`[vars]`-stripping
trick, a hand-written launcher because there's setup to do before `exec`)
than to `packages.logseq-sync` — with one real difference: this target's
Worker also binds a D1 database, so its launcher runs `wrangler d1
migrations apply` before `wrangler dev`. That command prompts for
confirmation whenever stdin is a real terminal even though nothing in the
launcher can answer it — fixed by redirecting stdin from `/dev/null` for
just that one command (verified: wrangler's own source, `is-interactive.ts`/
`dialogs.ts`, gates the prompt on `isNonInteractiveOrCI()`, which is
"no TTY on stdin" **or** `CI` env var; closing stdin was chosen over setting
`CI=1` for the whole launcher because that flag has a much wider blast
radius — it also reformats `wrangler dev`'s own output and disables its
interactive hotkeys, which the migration-prompt fix has no business
touching).

**REST API and MCP.** Three things had to change for them to answer with
data rather than errors, all proven by `checks.sync-worker`:

1. The `wrangler.toml` strip keeps the `[[ratelimits]]` bindings between
   `[vars]` and `[env.*]` — without them every semantic call is a 503
   ("rate limiter unavailable"). wrangler provides them locally.
1. `db-sync.patch` answers `/mcp` without a token with a bare
   `WWW-Authenticate: Bearer` 401; upstream serves `initialize`/`tools/list`
   anonymously, so MCP clients never start OAuth. No `resource_metadata` URL
   in that header: wrangler rewrites an absolute URL in a response *header*
   back to its listen address (not in a body), and clients fall back to
   `/.well-known/oauth-protected-resource/mcp` on the URL they connected to.
1. That metadata's `resource` comes from `request.url`, which behind a TLS
   proxy is the listen address; MCP clients reject a mismatch. The launcher
   passes `SYNC_WORKER_PUBLIC_URL` (module `publicUrl`) to `wrangler dev
   --local-upstream`/`--upstream-protocol`, which rewrites `request.url`.

The realm side (scopes, audience) is in the README's "REST API and MCP" and
`examples/keycloak.nix`. MCP clients reuse the realm's public `logseq`
client (Claude Code `--client-id`, opencode `oauth.clientId`), so `aud`
stays `logseq` without `COGNITO_CLIENT_IDS`. Not run: the real Claude Code
and opencode binaries (the check replays their OAuth requests), and dynamic
client registration (Keycloak's anonymous-registration policies would need
configuring, and a registered client's `aud` would differ).

### Android app (`packages.logseq-android`)

Done, and no longer impure. Used to be the whole Gradle build wrapped as one
fixed-output derivation (Gradle has no lockfile to build a fetch-then-
offline-build split against, unlike deps.edn's `:mvn/version` pins or
pnpm-lock.yaml). Now uses nixpkgs' own solution to exactly that problem —
`gradle.fetchDeps`/`mitm-cache` (used for real by e.g. nixpkgs'
`animeko` package) — instead of the originally-sketched "capture
`~/.gradle/caches`" plan, which turned out to carry real determinism risk
(Gradle's own `journal-1`/`modules-2.lock` files embed timestamps, not
guaranteed stable across capture runs) that MITM-recording the Maven HTTP
traffic into a URL→hash lockfile (`modules/packages/android-deps.json`)
avoids entirely — only immutable artifact bytes get hashed, never Gradle's
internal cache bookkeeping.

`clientConfig` overrides are **free now** — no `hash` argument, no
`lib.fakeHash` dance. Verified, not assumed: built with an overridden
`apiDomain` and no hash override at all; only the final compile derivation
rebuilt (every Maven-artifact fetch was reused unchanged, since
`applyClientConfig` patches `.cljs` string literals and never touches
`build.gradle`/AGP config, so the dependency set — and therefore
`android-deps.json`'s content and the `mitmCache` FOD's hash — is completely
independent of `clientConfig`), and the bundled `main.js` inside the
resulting unsigned `app-release-unsigned.apk` (~39.5MB, same size as
before) carried the override.

One genuinely non-obvious mechanic, worth knowing before touching this file:
`gradle.fetchDeps`'s update script (the thing that regenerates
`android-deps.json`) only runs `unpackPhase -> patchPhase -> configurePhase
-> gradleUpdateScript` — it never reaches a custom `buildPhase`. That's why
the whole pnpm/gulp/cljs/webpack/`cap sync` pipeline now lives in
`preConfigure`, unlike every sibling target (which keep `preConfigure` to
setup and put the real build in `buildPhase`) — `preConfigure` is the one
hook point that fires on both the capture path and the real build path.
Confirmed by reading nixpkgs' `update-deps.nix` directly. Getting this
right needed one real iteration: putting `pnpmConfigHook` (normally a
`postConfigure` hook, i.e. after this whole `preConfigure`) *after* the
`packages/ui` pnpm install broke `packages/ui`'s own `postinstall` (a
`parcel build` that resolves a hoisted polyfill from the *root* install),
with a genuinely confusing symptom (`process/ ... auto install is
disabled`) until traced back to hook ordering by diffing against a working
`logseq-webapp` build log. Fixed by calling `pnpmConfigHook` manually, in
the right spot, with `dontPnpmConfigure = true;` to stop it from also
auto-running (redundantly) later.

Uses nixpkgs' own Gradle (`pkgs.gradle`, 8.14.4) rather than
`android/gradlew` (the project's own wrapper pins 8.14.3) — the
`mitm-cache`/`gradle.fetchDeps` plumbing is built entirely around the
`gradle` shell function nixpkgs' setup hook installs, not an arbitrary
`./gradlew`-downloaded distribution, and the patch-version gap hasn't
caused any AGP/Kotlin incompatibility.

Getting a real `assembleRelease` to succeed under this system's sandboxed
Nix needed three separate fixes from the original impure-FOD work, all
still true and all in project memory (`logseq-android-package.md`):

1. `androidenv` needs `allowUnfree` + `android_sdk.accept_license`, set by
   re-importing nixpkgs locally rather than threading it through the flake.
1. **AAPT2 "Daemon startup failed"**, in two independent layers: the SDK's
   own `build-tools/*/aapt2` needs `autoPatchelfHook` (excluding
   renderscript's on-device-only `.so` files from the scan), **and**
   separately AGP downloads its *own* aapt2 from Google's Maven repo at
   build time that patching the SDK alone never reaches — fixed with
   `-Pandroid.aapt2FromMavenOverride=<patched aapt2 path>`, passed via
   `gradleFlags` so it's present during both the `android-deps.json`
   capture and the real build. AGP never actually reached for the
   Maven-hosted aapt2 during capture either (verified: no separate error
   for it in the capture log), so this gotcha needed no special handling
   in the new two-phase design — confirmed empirically, not assumed.
1. Some AAR subprojects (`@aparajita/capacitor-secure-storage`) pin a
   `build-tools` version Gradle tries to auto-install mid-build, which
   fails against a read-only SDK — fixed by pre-including every version
   any subproject wants in `buildToolsVersions`.

### Publish service (`packages.logseq-publish`)

Done — and the plan this was written against turned out to be **wrong on its
central premise**, which is worth recording:

> "Because there's no env-var config path, making it configurable will need the
> same build-time `clientConfig` patching mechanism the client targets use."

There is no hardcoded endpoint in `deps/publish` to patch. Every Cognito value
and R2 credential is read off the **worker's `env` binding at request time**
(`aget env "COGNITO_ISSUER"` etc. in `src/logseq/publish/common.cljs`, and
`deps/common/src/logseq/common/authorization.cljs`, which the worker shares with
sync). `deps/publish` never requires `cognito_config.cljs` — that file is
client-side only, so `applyClientConfig` was never going to touch this target
either. What upstream's `worker/wrangler.toml` `[vars]` block does is feed those
env values at *deploy* time; the package strips everything from `[vars]` on (its
Cognito pool, the staging/prod environments, the `logseq.io` custom domain) and
sets `CLOUDFLARE_INCLUDE_PROCESS_ENV=true` instead, so the worker gets
`process.env`. Net result: **`logseq-publish` takes no `clientConfig`, exactly
like `logseq-sync`** — config is plain runtime env vars. The `grep -q '^\[vars\]'`
before the `sed` in `installPhase` is there so the build fails loudly rather
than silently shipping upstream's pool if that block ever moves.

The only hardcoded URLs left in `deps/publish` are `asset.logseq.com` links to a
social banner and a favicon in `render.cljs` — cosmetic, not identity/sync/
publish endpoints. Same class of residual gap as the webapp's version-check
ping.

**Runtime: wrangler's local (workerd) runtime, not Node.** The worker stores page
metadata in a SQLite-backed Durable Object and blobs in R2. Unlike `deps/db-sync`
there is no Node adapter to build instead, and both of those bindings are
workerd features — a Node HTTP shim would have to reimplement them. `pkgs.wrangler`
(4.93.0, ships its own workerd) provides both in local mode, which is also what
the existing production deployment does with the third-party image. Verified: no
network needed at startup, DO and R2 bindings resolve, `COGNITO_*` arrive on
`env`.

Two non-obvious runtime facts, both worked out empirically and now in the
launcher's comments:

1. wrangler resolves `main` **relative to the config file** and puts its own
   esbuild scratch dir (`.wrangler/tmp`) beside it — so the config cannot stay
   in the read-only store. The launcher links `dist/` and `wrangler.toml` into
   `$PUBLISH_DATA_DIR` and runs from there. This is a hand-written script rather
   than `makeWrapper` precisely because there is work to do before `exec`.
1. `node_modules` has to be a **symlink farm, not one symlink** to the store
   directory: miniflare caches its `Request.cf` placeholder in
   `node_modules/.mf`, and a read-only `node_modules` turns that into an ENOENT
   stack trace on every reload (non-fatal, but it looks like a real failure).
   `shopt -s dotglob` so pnpm's own symlinks into `.pnpm/` and `.bin/` come
   along.

Build side, as predicted: `deps/publish` has its own `package.json`/
`pnpm-lock.yaml` (one `mkPnpmDeps` call, third call site) and needed one more
`clj -P` pass in the shared `clojureDeps` cache — its `deps.edn` pins no
`org.clojure/clojurescript`, so shadow-cljs drags in 1.12.145 next to root's
1.12.134. Every *other* Maven coordinate it names was already covered by root's,
as the earlier research said.

One prediction that did *not* hold: the `mldoc` splice `sync.nix` carries is
not needed here, so the `fetchzip` was written, found redundant and deleted.
Chasing why exposed a **wrong diagnosis in `sync.nix`**, since corrected there:
`fetchPnpmDeps` never "silently dropped" mldoc. `deps/db-sync/package.json`
simply does not declare it — nor does its lockfile — while its `deps.edn` pulls
in `logseq/outliner` as a `:local/root`, whose cljs reaches the `["mldoc"]`
require, so the compiled `node-adapter.js` needs a package db-sync never asked
for. `deps/publish` declares `mldoc` itself, which is the whole difference. The
old comment's exit condition ("drop this if a future fetchPnpmDeps/pnpm bump
stops reproducing it") was therefore unreachable, and would have cost the next
reader a hunt for a fetcher bug that does not exist.

## Container images + compose

Done. `logseq-flake/modules/packages/images.nix` builds one
`dockerTools.buildLayeredImage` per deployable target — web app, sync, publish
— each wrapping the package that already exists rather than rebuilding
anything, and `logseq-flake/examples/docker-compose.yml` wires the three on
ports 8080/8081/8082 to match the shape already in production. All three were
loaded into podman and probed by hand; the web app's image also has a
`containers` check (VM + podman) because it is the only one with logic of its
own.

The web app's runner (the nginx conf, with its wasm and `.mjs` types, the
`user_info` stub and the runtime client config, plus the script that writes
that config and starts nginx) lives in `modules/packages/_webapp-nginx.nix`,
shared by this image, the `nix run` wrapper and `services.logseq-webapp`. It
takes a writable directory and resolves every relative path against it (the
image's own `/tmp`, a `nix run`'s `mktemp -d`, the service's state
directory), so one recipe covers all three instead of copies drifting apart.

**All three images are generic**: everything deployment-specific comes from
compose `environment:` entries, the servers' natively and the web app's through
the runner (`LOGSEQ_*`, keys in `modules/packages/_client-config.nix`). So they
can be built once and published. `checks.containers` gives the web app image
`LOGSEQ_*` variables and asserts they come back in its `js/logseq-config.js`.
The image still takes `clientConfig`, but only as baked defaults.

Four things worth knowing, none of which were obvious up front:

1. **The web app's nginx must serve `application/wasm` for `js/sqlite3.wasm`.**
   The browser refuses to instantiate it as anything else, and nothing says so
   until the DB worker dies. nixpkgs' `nginx` ships a `mime.types` that covers
   wasm, so including it is enough — but a hand-written server config or a
   minimal file server (`darkhttpd` and friends) would silently get this wrong.
   The same `mime.types` does *not* cover `.mjs`, which it serves as
   `text/plain`; browsers refuse that for a module script, and
   `js/pdfjs/pdf.mjs` is the PDF viewer. The recipe adds the one type.
1. **The `try_files … /index.html` fallback is a nicety, not a requirement.**
   An earlier version of this file said the app uses real paths. It doesn't:
   `frontend/core.cljs` starts reitit with `:use-fragment`, so routes are
   `#/login` and every reload fetches `/`. The fallback only turns a stray
   `/login` into the app instead of a 404.
1. **Both server images need `dockerTools.caCertificates`.** The JWKS fetch
   fails at certificate verification against any https issuer otherwise —
   invisible in the VM checks, where Keycloak is plain HTTP.
1. **nginx cannot drop privileges under `cap_drop: ALL`** (no `CAP_SETUID`), so
   the compose file and the check run that container as `65534:65534` and the
   image gives `/tmp` mode 1777 for nginx's pid file. `nginx -e stderr` is
   also needed, or every start logs a bogus "could not open error log file"
   alert before it parses the config (the bare keyword, not a `/dev/stderr`
   path — see the NixOS-modules section above for why that distinction
   matters at all).

`logseq-publish-image` is ~2.6GB, and ~2.2GiB of that is nixpkgs' `wrangler`,
which packages the upstream pnpm *monorepo*: three workerd builds at ~118MB
each plus vitest/typescript/turbo/every-platform esbuild, of which one workerd
and one package are used at runtime. Marked with a `ponytail:` comment rather
than trimmed — trimming means guessing which files wrangler loads, and the fix
belongs in the nixpkgs package, not here.

## NixOS service modules

Done: `flake.nixosModules.logseq-{webapp,sync,sync-worker,publish}`, one
module per package (`logseq-sync`/`logseq-sync-worker` stay separate
modules, not one with a variant option — incompatible storage). Each gets
`enable`, `package` (default `self.packages.${system}.logseq-<name>`, the
same re-export pattern `modules/packages/logseq.nix` already uses, so a
custom `clientConfig`/build is just a `package` override, not a new option
surface), `serviceName` (for cross-referencing from another module —
modeled on `modules/system/modules/nvme-of.nix`'s own hand-rolled option of
that name), `port`, `openFirewall`, and `user`/`group` (default `null` →
`DynamicUser`; setting `user` switches to a fixed `User`/`Group`, matching
this repo's `woodpecker-server.nix` precedent that `DynamicUser`'s
allocated UID doesn't survive reboot on an impermanent-root host). The
three servers additionally get `oidcIssuer`/`oidcClientId`/`oidcJwksUrl`
(no default — fails loudly if unset), `dataDir` (default `/var/lib/<serviceName>`; under `/var/lib`, nested paths included, it becomes `StateDirectory`,
which systemd creates for `user` and orders after the mount holding it;
elsewhere `ReadWritePaths` plus an explicit `RequiresMountsFor`) and, for
sync-worker/publish, four R2 placeholder options; sync-worker also has
`publicUrl` (see "REST API and MCP" above). `services.logseq-webapp` bundles its own dedicated
nginx process (reusing `_webapp-nginx.nix` verbatim — same recipe the
container image and `nix run` wrapper use) rather than leaving that to the
consumer, the one deliberate exception to how every other service in this
repo keeps nginx external: there's no backend to proxy to here,
nginx-serving-static-files *is* the service, not domain/TLS routing (a real
deployment still fronts it with an ordinary reverse-proxy vhost of its own,
same as any other service here). Its `clientConfig` option (one `nullOr str`
per key in `_client-config.nix`, so a typo fails evaluation) becomes the
runner's `LOGSEQ_*` environment: changing the identity provider restarts
nginx, it doesn't rebuild the bundle. `examples/keycloak.nix` is now a consumer
of the sync/sync-worker/publish modules (an optional `logseq-sync-worker`
parameter lets `checks.sync-worker` reuse the same realm setup without
duplicating it) instead of hand-rolling `systemd.services`.

Two real, non-obvious bugs found and fixed getting these running for real
under `pkgs.testers.runNixOSTest` (not just evaluated):

1. **`ln -sfnt` under `DynamicUser`+`StateDirectory`.** `sync-worker.nix`'s
   launcher symlinks the worker tree's contents into `$SYNC_WORKER_DATA_DIR`
   itself; under systemd, that path is a symlink (`/var/lib/<name> ->
   private/<name>`), and GNU `ln`'s `-n`/`--no-dereference` flag — present
   for no reason that mattered here — makes `ln -t` treat *that* a symlink-
   to-directory as a plain file instead of following it, failing with
   "target ...: Not a directory". `readlink -f` on the same path resolved
   fine; only `ln -t` with `-n` was confused. Fixed by dropping `-n` from
   that one call (`-f` alone still handles re-running against existing
   symlinks); a plain `nix run` or a container never hits this, since there
   the data dir is a real directory, not a systemd-managed symlink.
2. **nginx's `error_log`/`access_log` pointed at `/dev/stderr`/`/dev/stdout`
   paths work under a container or `nix run` (real pipes) but fail under
   systemd** (`open() "/dev/stderr" failed: No such device or address` —
   stderr there is a journal socket, and nginx's path-based `open()` can't
   reopen it). Fixed in the shared `_webapp-nginx.nix`: `error_log` now uses
   nginx's own magic `stderr` keyword (no path, no `open()` — same as
   nixpkgs' own `services.nginx` module defaults to, and why that module
   never hits this); `access_log` has no equivalent magic keyword, so it's
   simply `off` now (nothing anywhere reads it). Verified against all three
   consumers (container, `nix run`, this module) after the fix, not just
   the one that was failing.

One real **upstream** bug found, now fixed by `modules/packages/db-sync.patch`
(both sync targets): `deps/db-sync/src/logseq/db_sync/index.cljs`'s
`<user-upsert!`, called on every authenticated request, bound
`(aget claims "cognito:username")` straight into a D1 `.bind()`. Any
provider but Cognito omits that claim, and D1, unlike better-sqlite3 (the
Node adapter), rejects `undefined` with `D1_TYPE_ERROR: Type 'undefined' not
supported`. The patch falls back to the standard `preferred_username`, as
upstream's own `presence.cljs` already does; `self-hosting.patch` does the
same in the client's `parse-jwt`, so no provider needs a `cognito:username`
mapper, and Cognito, which sends it, is unaffected. `checks.sync-worker`
asserts the graphs list.

## Identity provider contract

Moved here from README.md, which now only states the short version for
consumers — this is the detail behind it.

**Servers accept any OIDC provider, proven, not just claimed.** `verify-jwt`
(`deps/common/…/authorization.cljs`, shared by both servers) does issuer,
audience, expiry and RS256-against-JWKS — no Cognito API calls anywhere in
that path. `examples/keycloak.nix` + `examples/logseq-realm.json` deploy both
servers against a self-hosted Keycloak realm; `checks.sync`/`checks.publish`
boot that module verbatim, log in as the realm's test user, and assert both
servers accept the token.

Two Keycloak-specific quirks the example realm works around, worth knowing
before adapting it to a different provider:

- **The audience mapper is load-bearing.** A stock Keycloak access token has
  `aud: ["account"]` and a separate `azp`, not the scalar `aud` `verify-jwt`
  wants — `logseq-realm.json` has a mapper that emits the client id as a
  plain string `aud` instead.
- **Upstream hardcodes Cognito's endpoint layout**
  (`https://<oauthDomain>/oauth2/token`, in the main thread and again in the
  db worker), which no other provider serves. With an `oidcIssuer`
  configured, the patch replaces both with the provider's discovery document, so
  nothing is rewritten in front of the realm. An earlier version of this work
  mirrored Cognito's paths and needed nginx rewrites for them; don't
  reintroduce that.

**Clients: sign-in is the OAuth device flow (RFC 8628), switched on at
runtime by an `oidcIssuer`**, the same issuer URL the servers get. Upstream's
login form is Amplify speaking Cognito's own API, so repointing `oauthDomain`
never made sign-in work. `modules/packages/self-hosting.patch` (applied to
every client build) makes the client read its config at runtime (see "Web
app" above) and, when that config has an `oidcIssuer`, replaces the login
form and both refresh paths: it reads the device and token endpoints from the
provider's discovery document, runs the device grant, and hands
`login-callback` the session shape it already expects. Without one, upstream's
Cognito form and refresh run unchanged, so the same generic bundle serves
both. Everything else downstream is upstream's own. The provider needs the
device grant on a public client, and CORS for the app origins.
**Staying signed in** needs two things a Cognito-shaped client lacks: it
asks for `offline_access` (the refresh token then outlives the SSO
session, 30 minutes idle by default), and it keeps the refresh token each
refresh rotates in (upstream drops it; a Keycloak refresh token dies at its
own `exp` however often it is used). The realm user needs the
`offline_access` role, or Keycloak answers `not_allowed` with no CORS
headers, which the app shows as "Failed to fetch". `checks.login` asserts
both from Keycloak's side.
**`user_info` is proven load-bearing**, and the web app's nginx now serves the
stub for it (point `apiDomain` at the web app). `checks.login` proves all of
it for the web app. **Desktop and Android run the same compiled code but are
not runtime-verified.** Why this mechanism and not a "Cognito-compatible" IdP
(none is usable) or redirect+PKCE, the negative `user_info` experiment, and
the traps: `docs/self-hosted-identity.md`.

**Endpoints are also settable at runtime, not just via `clientConfig`.**
Upstream reads two keys from `localStorage`, both exposed in Settings, so
they need no rebuild and are per-user: `sync-server-url` (overrides
`db-sync-http-base` and, derived from it via `https`→`wss`, `db-sync-ws-url`
— also flips `rtc-group?`, clearing the alpha/beta gate on fetching remote
graphs) and `publish-server-url` (the publish API base). So `clientConfig`'s
`syncUrl`/`publishUrl` are *defaults* for a preconfigured deployment
(`syncUrl` takes the same form as that Settings field, and the patch derives
the websocket URL from it the same way, so there is no `%s` to get wrong),
not the only lever. The identity keys
(`oidcIssuer`, `cognitoClientId`, `oauthDomain`, `apiDomain`, `cognitoIdp`,
`userPoolId`) have no per-user equivalent; they're per deployment (`LOGSEQ_*`
for the web app, baked for desktop and Android).

**Identity brokering example**: Keycloak sits between the clients and
whatever actually authenticates the user — it doesn't have to be a
Keycloak-local password. Identity brokering lets Keycloak delegate login to
another OIDC provider (e.g. a self-hosted GitLab or Forgejo/Gitea, both of
which expose `/.well-known/openid-configuration` for their own OAuth
applications) and mint its own token afterwards, so the contract above
is unchanged — only
who the user types their password into moves. Register an OAuth application
on the GitLab/Forgejo side (redirect URI
`<keycloak-issuer>/broker/<alias>/endpoint`), then add to the realm export:

```json
"identityProviders": [
  {
    "alias": "gitlab",
    "providerId": "oidc",
    "enabled": true,
    "config": {
      "clientId": "<oauth-application-id>",
      "clientSecret": "<oauth-application-secret>",
      "authorizationUrl": "https://gitlab.example.com/oauth/authorize",
      "tokenUrl": "https://gitlab.example.com/oauth/token",
      "userInfoUrl": "https://gitlab.example.com/oauth/userinfo",
      "issuer": "https://gitlab.example.com",
      "defaultScope": "openid email profile"
    }
  }
]
```

This is realm config only, so `nix flake check` doesn't exercise it (that
would need a live external instance to log into). With the device flow the
brokered login happens on Keycloak's own pages in a browser, so it needs
nothing from the client.

## Next up

### 1. Client sign-in: what's left

Client sign-in against a self-hosted IdP is done for the web app and proven
(see "Identity provider contract" above, and `docs/self-hosted-identity.md`
for the detail and traps). Remaining, roughly in order of value:

1. **Runtime-verify desktop and Android.** Desktop could get a VM check: the
   Electron binary under the same CDP driver `checks.login` uses. Android
   can't be exercised in a NixOS VM.
1. **`logseq login` (the CLI)** still does auth-code + PKCE against
   `https://<oauthDomain>/oauth2/authorize` and `/oauth2/token` with its own
   `CLI-COGNITO-CLIENT-ID`, none of which `applyClientConfig` patches. It
   would want the same discovery treatment (the realm already allows
   `http://localhost:*` redirects). Not attempted. Until then, don't run the
   CLI against a self-hosted-IdP build's `~/logseq/auth.json`: it would try
   to refresh those tokens at Cognito.
1. **Sign-out ends the app session, not the IdP's.** Amplify's `signOut` has
   no tokens to revoke, so signing in again skips the IdP password prompt
   while its session cookie lives. Probably fine; revisit if it isn't.
   It also leaves the offline session (and its refresh token) alive on
   Keycloak until it idles out after 30 days.

### 2. Literals `clientConfig` still misses

`REGION` and `IDENTITY-POOL-ID` in `src/main/frontend/config.cljs` are dead
with the device flow: Amplify never holds tokens, so it never calls AWS. That
makes them "remove", not "add". The `https://api.logseq.com/logseq/version`
update-check ping is the one live upstream call left. It's cosmetic, and cheap
to route through the runtime config if anyone cares.

### 3. `apiDomain` is still a bare host

Sync and publish are full URLs (`LOGSEQ_SYNC_URL`, `LOGSEQ_PUBLISH_URL`;
renamed from `syncHttpBase`/`syncWsUrl`/`publishApiBase`, the websocket URL
now derived in the patch's `db-sync-ws-url` and, for the CLI, in
`applyCliConfig`). `apiDomain` isn't: upstream prepends `"https://"` at its
two call sites (`frontend/handler/user.cljs:397`, `:424`), which is also why
`checks.login` needs TLS for `app.test`. Proposed, not done: an `apiUrl` key
(`LOGSEQ_API_URL`), patching those two sites.

## Boundaries (intentionally not touched)

- The live production deployment
  (`./modules/system/hosts/server/hypervisor/services/logseq.nix` in the
  parent configuration, domains `notes.krsnik.at`/`sync.notes.krsnik.at`/
  `blog.krsnik.at`, plus its Keycloak in `keycloak.nix` beside it) is a
  running service with real data. On 2026-09-29, when asked, it was rewritten
  from the third-party `logseq-selfhost` containers to this flake's modules
  (web app, sync worker, publish, all against its Keycloak), uncommitted for
  the owner to review and deploy. Never commit or deploy there; change it
  only when asked.
- NixOS service modules (`services.logseq-{webapp,sync,sync-worker,publish}`)
  are done — see "NixOS service modules" above.
- The desktop client's home-manager module (`programs.logseq` — see
  "Desktop client" above) has no permanent `nix flake check` entry, unlike
  its NixOS counterpart. Verified for real all the same (see that section),
  just not kept as a standing check: doing that properly needs
  `home-manager` itself as a flake input, and adding a real dependency
  purely to test what is, underneath, a well-established nixpkgs pattern
  (`home.packages` + `xdg.autostart.entries`, identical in shape to
  upstream's own `programs.keepassxc`) wasn't judged worth it. Revisit if
  the module ever grows real logic of its own.
- The parent configuration's own
  `./modules/home/configuration/logseq.nix` already had `flake.homeModules.logseq`
  setting `programs.logseq = { enable = true; autostart = true; };` *before*
  this module existed anywhere — the option didn't resolve to anything,
  since nothing imported a definition for it. That pre-existing (broken)
  config is exactly what fixed the shape of the option surface here
  (`enable`+`autostart`, not something else invented independently), and it
  is not otherwise touched by this work: it still needs
  `inputs.logseq.homeManagerModules.logseq` added to its own `imports` (or
  to `modules/nixosConfigurations.nix`'s `homeConfiguration` list) to
  actually take effect, which is a change outside `./logseq-flake/` and
  wasn't made without being asked.

## Architecture

Everything lives in `./logseq-flake/`, its own flake — nothing in it reaches
outside the `pkgs.*`/`inputs.*` args `callPackage` hands it, so it can be
moved to its own repository as-is. The move was verified derivation-for-
derivation: all four `drvPath`s were byte-identical before and after.

- `modules/packages/_common.nix` — shared FODs/helpers, returns a plain
  attrset (not a derivation): `src` and the git-lib sources (both now flake
  inputs — see `flake.nix` — rather than `fetchFromGitHub` calls here) +
  `setupGitLibs`, `fakeGit`, `fetchDeps` (the fetcher-shaped Maven-FOD
  helper), `clojureDeps` (covers root **and** `deps/db-sync`'s **and**
  `deps/publish`'s Maven deps in one shared cache — see the comment there
  before adding a new Maven FOD for anything), `pnpmDepsRoot`/`pnpmDepsUi`/
  `pnpmDepsSync` (the last one shared by `sync.nix` **and**
  `sync-worker.nix` — same lockfile, two different shadow-cljs build ids),
  `mldocSrc` (the `mldoc` splice, also shared by both sync targets),
  `mkPnpmDeps` (helper for any standalone `--ignore-workspace` pnpm
  subproject), `pnpmStoreHelper`, `setupSources` (the identical opening
  every target's `preConfigure` had), `applyClientConfig` (applies
  `./self-hosting.patch` and bakes `clientConfig` into
  `resources/{,mobile/}js/logseq-config.js`, rejecting keys that aren't in
  `_client-config.nix`) and `applyCliConfig` (the OCaml CLI's own literals,
  `cli/lib/{auth_state,cli_config}.ml`, substituted from
  `defaultClientConfig`, which holds upstream's values).
  Takes `inputs` as a parameter (threaded in by every `callPackage
  ./_common.nix { inherit inputs; }` call site) since plain `inputs` is not
  a valid `perSystem` module arg in flake-parts — every package file's
  top-level module is `{ inputs, ... }: { perSystem = ...; }` for exactly
  this reason.
- `modules/packages/desktop.nix` — the Electron client; everything genuinely
  desktop-only (OCaml/melange CLI toolchain, keytar, the desktop item) lives
  here.
- `modules/packages/webapp.nix` — static web bundle, a strict subset of
  desktop's pipeline.
- `modules/packages/sync.nix` — the sync server (`deps/db-sync`'s plain-Node
  adapter); env-var config, own pnpm/Maven fetches.
- `modules/packages/sync-worker.nix` — the sync *worker* (`deps/db-sync`'s
  Cloudflare Worker build — semantic REST/MCP/ChatGPT-Apps, D1+DO+R2
  storage); see its own section above for why it's structurally closer to
  `publish.nix` than to `sync.nix`, and why its storage is incompatible with
  `sync.nix`'s.
- `modules/packages/publish.nix` — the publish service; the only target
  besides `sync-worker.nix` that ships a hand-written launcher instead of
  `makeWrapper`, and (along with `sync-worker.nix`) the only ones whose
  runtime is `wrangler`/workerd rather than Node or a browser. Read its
  header before assuming it needs `clientConfig`; it doesn't, and the reason
  is structural.
- `modules/packages/android.nix` — the Android app; see its own section
  above for why it's structurally different from the rest (one mega-FOD).
- `modules/packages/_webapp-nginx.nix` — the web app's runner: an nginx conf
  plus the script that writes the client's runtime config from `LOGSEQ_*`
  variables (over the package's baked `passthru.clientConfig`) and execs
  nginx. Shared by `images.nix`'s container image, `modules/apps/webapp.nix`'s
  `nix run` wrapper and `services.logseq-webapp`; not itself a flake-parts
  module (the `_` prefix), just a `callPackage`-able function.
- `modules/packages/_client-config.nix` — every `clientConfig` key and its
  `LOGSEQ_*` variable: the one list the build, the runner and the NixOS
  module check against.
- `modules/packages/self-hosting.patch` — the client-side patch, applied to
  every client build: runtime config, and device-flow sign-in and refresh
  against an OIDC provider when one is configured.
- `modules/packages/desktop.patch` — an upstream bug fix for the desktop app
  only: plugin installs unzipped the download before it was fully written
  ("end of central directory record signature not found").
  Timing-dependent, so upstream builds hit it too (same Electron 42).
- `stdenv` vs `stdenvNoCC`, and `finalAttrs`: every `mkDerivation` in
  `modules/packages/` uses the `stdenv.mkDerivation (finalAttrs: {...})`
  form (self-referencing `finalAttrs.pname` etc. to kill duplicated
  literals — bin names, share dirs, `mainProgram`). Full `stdenv` (not
  `stdenvNoCC`) is only used where
  something genuinely compiles natively at build time: `sync.nix`/
  `sync-worker.nix` (deps/db-sync's `better-sqlite3` node-gyp addon),
  `desktop.nix`'s main derivation (`keytar`'s node-gyp addon) and its
  `cliBundle` (OCaml's ppx-preprocessor compilation shells out to `as`, the
  assembler, even though the CLI's own output is pure melange/JS — tested,
  not assumed: swapping `cliBundle` to `stdenvNoCC` fails with `sh: as: not
  found` compiling `melange.ppx`, before any of the CLI's own sources are
  touched). Every other target (`webapp.nix`, `publish.nix`,
  `_common.nix`'s `fetchDeps`/`clojureDeps`, `android.nix` — both its own
  derivation and `androidSdkPatched`) uses `stdenvNoCC`.
- `flake.nix` — flake-parts `mkFlake`, `systems`, `imports = [
  (inputs.import-tree ./modules) ]`, and the pinned-source inputs
  (`logseq-src` + the ~10 git-lib inputs, all `flake = false`) described
  above.
- Each target file above is itself a flake-parts module that registers its
  own `perSystem.packages.<name>`, wrapping a plain `callPackage` function
  — so `.override { clientConfig = ...; }` still works and the derivations
  stay usable from an ordinary overlay. `_common.nix`/`_webapp-nginx.nix`
  keep their underscore because import-tree skips any path containing `/_`:
  they are shared build machinery, not modules. A per-system restriction
  belongs to the package that has it (`android.nix` gates its own attribute
  on x86_64-linux) — but *inside* `packages`, never around the whole
  `perSystem` module, or flake-parts can no longer statically rule out a
  `formatter` output and `nix flake check` fails.
- `modules/apps/{webapp,sync,sync-worker,publish}.nix` — `nix run
  path:.#logseq-<name>` for every server/webapp target; see the checks-table
  paragraph above for what each wrapper actually does and why.
- `modules/nixos/{webapp,sync,sync-worker,publish}.nix` — the
  `services.logseq-*` modules, see "NixOS service modules" above.
  `modules/nixos/_common.nix` factors their shared option/hardening shapes
  (same underscore-skipped-by-import-tree convention as
  `modules/packages/_common.nix`), which each module `import`s directly
  rather than via flake-parts `imports` — it's a plain helper, not a
  NixOS submodule itself.
- `modules/nixos/desktop.nix` and `modules/home-manager/desktop.nix` — the
  `programs.logseq` NixOS and home-manager modules, see "Desktop client"
  above. Standalone rather than built on `modules/nixos/_common.nix`'s
  `mkServiceOptions`: there's no port/serviceName/user-group surface that
  applies to a desktop app, so reusing that helper would mean carrying
  options that do nothing.
- `modules/packages/images.nix` — one OCI image per deployable target (web
  app, sync, publish; no `sync-worker` image yet), all generic and configured
  from the environment. The web app's runs the runner; its `clientConfig`
  argument only bakes defaults.
- `modules/checks.nix` — one check per target, reading `config.packages`
  from the same `perSystem`; anything that answers on a port gets a NixOS VM
  test (`pkgs.testers.runNixOSTest`) — the two servers share one node
  definition, the `stack` binding, so the Keycloak example is described once —
  while the desktop app and the APK get plain `runCommand` derivations, because
  neither has a port to knock on.
- `examples/keycloak.nix` + `examples/logseq-realm.json` — a copyable
  self-hosted-IdP deployment of *both* servers that `modules/checks.nix` boots
  verbatim (the `sync` and `publish` checks share one node definition), so the
  example cannot rot. Read its comments before adapting the realm.
- `examples/docker-compose.yml` — the three images as a stack, podman- and
  docker-compatible. Its `LOGSEQ_*` variables have no defaults on purpose, so
  it fails loudly rather than quietly falling back to upstream's Cognito pool
  and api.logseq.io.
- `README.md` — the outward-facing version of this file.
- `docs/self-hosted-identity.md` — how clients sign in against a self-hosted
  IdP (the device-flow patch, the `user_info` stub), what's proven and what
  isn't, with verified file:line references and the traps already fallen into
  once.

Outside the flake, `./modules/packages/logseq.nix` re-exports
`inputs.logseq.packages.<system>` so `nix build path:.#logseq` keeps
working. Its checks are deliberately *not* re-exported: `nix flake check`
on this configuration has no business building an Android SDK.

## Resources

- Logseq source (rev 2.0.1): `./logseq`
- `./logseq-selfhost` — third-party container-image project (build
  commands and env var conventions only, no Nix; not authoritative for
  anything Nix-shaped)
- `./logseq-nixos-module` — an earlier, unfinished attempt at this exact
  task. Its FOD hashes matched the real package's exactly where compared
  (safe to trust as already-verified values), but its code patterns have
  since been superseded — see `logseq-package-split` in project memory for
  specifics before reusing anything from it.

## Notes / process

Use `nix build path:.#<target>` to verify progress, but treat a successful
build as necessary, not sufficient — every target above was also
runtime-smoke-tested (curl a server, grep a compiled bundle for an
override, serve static files and fetch them) because a build succeeding
only proves the derivation evaluates and compiles, not that the result
actually works or that a config override actually reached it.

Work in milestones. Each one ends with: verify (`nix build` + a runtime
check) → commit on the `feature-logseq` branch → update memory with what
was learned (insights, workarounds, dead ends — not just successes) →
re-read the whole `./logseq-flake/` directory fresh and look for duplication or
complexity the next milestone's real requirements have made unnecessary,
and simplify before moving on. Don't defer the simplify step to "later" —
do it every time, while the context is still fresh. This loop already
caught one real duplication (three near-identical `fetchPnpmDeps` calls,
factored into `mkPnpmDeps`) and one accidental over-complication introduced
and reverted before it ever landed.

Document non-obvious parts via an inline comment (why, not what). Project
memory (queryable by a fresh session) has the full detail behind every
"done" claim above — this file is the map, not the territory.

## Open Tasks

The goal is a full end-to-end self-hosted setup with a custom identity provider.

Make the clients talk to any OICD provider and not just cognito.
Using patch files (applied in the nix build) is a viable strategy if it cannot be solved simpler.

Extra Context for self-hosted setups:

<https://abhilesh.github.io/blog/2026/self-hosting-logseq-sync/>

<https://medium.com/@4shutosh/how-to-self-host-logseq-db-graph-sync-d62d589f06a4>
