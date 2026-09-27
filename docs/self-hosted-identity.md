# Plan: a self-hosted identity provider that the clients can actually use

Status as of 2026-09-26. The servers are done and proven; the clients are not.
This is the plan for closing that, written so a fresh session can execute it
without re-deriving the analysis. Every file reference is to the upstream
checkout at `../logseq` (rev 2.0.1).

## Where things actually stand

| Piece | State | Evidence |
| - | - | - |
| Sync + publish accept any OIDC provider | **done, proven** | `checks.sync`, `checks.publish` — realm-minted token gets 200/404, 401 without |
| Token contract the clients need | **done, proven** | `checks.sync` asserts `exp`/`sub`/`email`/`cognito:username` on the id token, and refresh through the `/oauth2/token` rewrite |
| Endpoint overriding | **done, and largely already upstream's** | `localStorage` `sync-server-url` / `publish-server-url`, both in Settings; `clientConfig` only supplies defaults |
| `user_info` on the critical path | **unknown — blocks everything below** | read from source only; never executed |
| Sign-in against a non-Cognito IdP | **not started** | the amplify component |

Read `../README.md`'s "Setting the identity provider" section and
`../AGENTS.md`'s "Identity provider contract" section first; together they
state the same split, briefly and then in full. The rest of this file is
the part that is not done.

## Phase 1 — settle the `user_info` dependency

**This is the gate. Do it first, and do not start Phase 2 until it is answered**,
because if the logged-in flow cannot complete without a service we do not
provide, a working sign-in button buys nothing.

### The question

`:user/fetch-info-and-graphs` (`src/main/frontend/handler/events/ui.cljs:446`)
does nothing unless `<user-info` returns a map:

```clojure
(let [result (async/<! (user-handler/<user-info user-handler/remoteapi))]
  (cond
    (instance? ExceptionInfo result) nil      ; <- silently gives up
    (map? result) (do ... fetch graphs, start RTC ...)))
```

`<user-info` (`src/main/frontend/handler/user.cljs:515`) is `POST https://<API-DOMAIN>/file-sync/user_info`
with `Authorization: Bearer <id-token>` (`<request-once`, `src/main/frontend/handler/user.cljs:428`).
`API-DOMAIN` defaults to `api.logseq.com` and is `clientConfig.apiDomain`.
**Nothing in this flake implements that endpoint, and `deps/db-sync` does not
either** — it is upstream's user/file-sync API, a third service beyond sync and
publish.

So: does a self-hosted deployment need a `user_info` implementation, and if so,
what is the minimum response?

### What is already known (from source, not execution)

Only `:UserGroups` is load-bearing, and every read is nil-safe:

- `state/user-groups` → `(set (get-state [:user/info :UserGroups]))` (`src/main/frontend/state.cljs:792`)
- `alpha-user?` / `beta-user?` → membership of `"alpha-tester"` / `"beta-tester"`
- `src/main/frontend/components/settings.cljs:968` reads `:LemonStatus`, `:UserGroups`, `:LemonEndsAt`,
  `:LemonRenewsAt`, all via `some->` / set-membership — a missing key renders as
  the free plan, it does not throw
- `src/main/frontend/components/header.cljs:541` reads `:UserGroups` only

And the graph-fetch gate is satisfiable two independent ways
(`src/main/frontend/handler/events/ui.cljs:460`, `src/main/frontend/handler/user.cljs:359`):

```clojure
fetch-graphs? (and (logged-in?) (or (= status :welcome)   ; alpha-or-beta-user?
                                    (rtc-group?)))       ; true if sync-server-url is set
```

So the expectation — **to be confirmed, not assumed** — is that
`{"UserGroups": []}` is enough, because `rtc-group?` is already true whenever a
custom sync server URL is configured. `{"UserGroups": ["rtc_2025_07_10"]}` would
satisfy the gate without relying on that, and is the safer stub.

### The experiment

Reuse the node that already exists — `examples/keycloak.nix` boots the realm,
sync and publish, and `checks.sync`/`checks.publish` share it via the `stack`
binding in `modules/checks.nix`. Add to it:

1. **An nginx vhost with TLS**, serving the web app bundle *and* the stub, on one
   origin. TLS because `<request-once` hardcodes the `https://` scheme, so a
   plain-HTTP `apiDomain` is unreachable; one origin because that makes the
   `user_info` POST same-origin and sidesteps CORS entirely. A self-signed cert
   plus `--ignore-certificate-errors` on the browser is fine for a check.
   ```nginx
   location = /file-sync/user_info {
     add_header Content-Type application/json;
     return 200 '{"UserGroups":["rtc_2025_07_10"]}';
   }
   ```
   If this turns out to be sufficient, **that nginx block is the whole fix** — no
   new package, no new service. Aim for it before writing anything larger.
1. **A web app built for this VM**: `logseq-webapp.override { clientConfig = { apiDomain = "<vhost>"; syncHttpBase = …; syncWsUrl = …; }; }`. Budget a full
   cljs rebuild (~18 min) per config change, so get the config right in one go.
1. **A seed page on the same origin** that plants the three tokens and navigates
   to the app — this is what stands in for the sign-in button:
   ```
   location = /seed.html { ... localStorage.setItem('id-token', …) ×3,
                               localStorage.setItem('sync-server-url', …),
                               location = '/' ... }
   ```
   Tokens come from the realm by password grant, exactly as `checks.sync` already
   does. Inject them into the page via a query string or a generated file.
1. **Headless chromium**, pointed at `/seed.html`.

**Observe from the server side, not the DOM.** If the app reaches logged-in
state it calls the sync server with a bearer token, so the assertion is "an
authenticated request arrived at `logseq-sync`" — no browser introspection, no
scraping. Watch the service's journal, or assert on a request the sync server
logs.

### Acceptance

- With the stub: an authenticated request from the browser reaches `logseq-sync`.
- Without the stub (`user_info` returning 500): it does not. **Run this half
  too** — it is what proves the stub is load-bearing rather than incidental, and
  it is the cheap way to find out that the whole concern was misplaced.
- Whatever the outcome, record it in `../../AGENTS.md`: this is currently the
  single biggest unknown in the project and it should stop being one.

### Known risks

- The app may fail headless for reasons unrelated to identity (OPFS, wasm,
  service worker). Establish that the bundle boots and reaches *anonymous*
  working order in the VM **before** adding tokens, or a failure is unattributable.
- `<request*` retries up to 5 times; a stub that 500s will take a while to give
  up. Keep the negative case's timeout generous.
- Chromium's closure is large. If the VM disk or build time becomes the problem,
  `virtualisation.diskSize` is the first knob (the `containers` check already
  sets it).

## Phase 2 — generic OIDC sign-in

Only worth starting once Phase 1 is green. The good news, and the reason this is
smaller than "rewrite login": **all Cognito coupling sits behind one global with
four members.**

### The seam

`packages/ui/src/ui.ts:212` does `window.LSAuth = amplifyAuth`, where
`packages/ui/src/amplify/index.ts` exports exactly `{ init, Auth, LSAuthenticator }`.
`src/main/frontend/components/user/login.cljs` is the only consumer — there is no
separate mobile or desktop login component — and it uses:

| Use | Site |
| - | - |
| `(.init js/LSAuth #js {:authCognito {…region, userPoolId, userPoolClientId, identityPoolId, oauthDomain}})` | `src/main/frontend/components/user/login.cljs:25` |
| `(.-LSAuthenticator js/LSAuth)` as a React component | `src/main/frontend/components/user/login.cljs:27` |
| `(.signOut js/LSAuth.Auth)` | `src/main/frontend/components/user/login.cljs:18` |

`LSAuthenticator` takes props `{titleRender, onSessionCallback}` and a
**render-prop child** receiving `op` with `.signOut` and `.sessionUser`
(`src/main/frontend/components/user/login.cljs:66-71`). The session it must produce is the amplify shape, because
`login-callback` (`src/main/frontend/handler/user.cljs`) destructures it:

```clojure
(:jwtToken (:idToken session))      ; sessionUser.signInUserSession.idToken.jwtToken
(:jwtToken (:accessToken session))
(:token (:refreshToken session))
```

### So the work is

Write a drop-in `LSAuth` that performs Authorization Code + PKCE against any
OIDC provider and returns a `signInUserSession`-shaped object. Everything
downstream — `set-tokens!`, localStorage, refresh, the servers — is already
provider-neutral and needs no change.

Two details that make this cheaper than it looks:

- **`auto-fill-refresh-token-from-cognito!` and `clear-cognito-tokens!`
  (`src/main/frontend/handler/user.cljs:130-150`) degrade to no-ops.** They scan localStorage for
  `CognitoIdentityServiceProvider.*` keys; with none present they do nothing. An
  adapter that writes `refresh-token` itself needs no change there.
- The cljs passes the config under the key `authCognito`. Either accept that key
  name in the adapter (zero cljs changes) or substitute one line via the existing
  `applyClientConfig` mechanism in `modules/packages/_common.nix`. **Prefer accepting the
  key** — the point is to touch upstream sources as little as possible.

### Acceptance

A VM check in the shape of Phase 1's, minus the seed page: drive the real
sign-in UI headless against the Keycloak realm, and assert an authenticated
request reaches `logseq-sync`. That is the check that would let the README drop
its "login is Cognito-only" caveat — do not drop it before then.

## Phase 3 — fold into the packaging

Only once Phases 1-2 are green:

- `clientConfig` gains whatever the adapter needs, and loses what it no longer
  does. `REGION` and `IDENTITY-POOL-ID` (`src/main/frontend/config.cljs:30-32`)
  are Cognito-only and become dead — remove rather than add them.
- `examples/keycloak.nix` grows the `user_info` location and the TLS vhost, so
  the example stays a complete working deployment.
- `examples/docker-compose.yml` and `modules/packages/images.nix`: if `user_info` ends
  up needing more than an nginx `return`, it becomes a fourth image. If the
  nginx block suffices, it belongs in the existing web app image and its config
  — resist making a service out of one static response.
- Rewrite "Setting the identity provider" in `../README.md` and "Identity
  provider contract" in `../AGENTS.md` around what is then true.

## Traps

- **Do not cite `AWSCognitoIdentityProviderService.InitiateAuth`** as evidence of
  the coupling. That call is in `login-with-username-password-e2e`
  (`src/main/frontend/handler/user.cljs:285`), an `^:export`ed test helper, not the login path. The
  amplify component is the real coupling. An earlier version of the docs got this
  wrong.
- **Do not add a runtime config path for sync/publish endpoints.** Upstream
  already reads them from localStorage and exposes them in Settings; a second
  mechanism is two things to keep in sync. `clientConfig` supplies defaults only.
- **Do not assume a build success means anything here.** Everything in this
  project that claims to work was runtime-probed, and the two findings that
  mattered most this round (the runtime overrides, the `user_info` dependency)
  came from reading the flow, not from a green build.
- **`oauthDomain` sets only a host.** The refresh path is a hardcoded
  `/oauth2/token`; Keycloak needs the rewrite in `examples/keycloak.nix`. Without
  it sign-in appears to work and dies at the first refresh, about an hour later.
