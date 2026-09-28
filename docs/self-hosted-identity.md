# Clients against a self-hosted identity provider

Status as of 2026-09-28: **done for the web app and proven end to end; built
the same way for desktop and Android, but not runtime-verified there.** File
references are to the pinned 2.0.1 source (the `logseq-src` flake input), not
to `../logseq`, which is a newer nightly with a rewritten login component.

| Piece | State | Evidence |
| - | - | - |
| Sync + publish accept any OIDC provider | done, proven | `checks.sync`, `checks.publish` |
| Token contract the clients need | done, proven | `checks.sync`: claims on the id token, discovery advertises the device endpoint, refresh at the discovered token endpoint |
| Endpoint overriding | done, mostly upstream's own | `localStorage` `sync-server-url` / `publish-server-url`; `clientConfig` supplies defaults |
| `user_info` on the critical path | done, proven load-bearing | stub in `modules/packages/_webapp-nginx.nix`; negative case below |
| Sign-in against a non-Cognito IdP | done for web, proven | `checks.login` (stock package, runtime config); `modules/packages/self-hosting.patch` |
| Token refresh against it (main thread) | done for web, proven | `checks.login`: Keycloak records a `REFRESH_TOKEN` event |
| Same, desktop and Android | built, not runtime-verified | same compiled code; see "Not verified" |

## How it works

Give the client an `oidcIssuer`: the provider's issuer URL, the same value the
servers' `oidcIssuer` takes, e.g. `https://auth.example.org/realms/logseq`. For
the web app that's runtime config (`LOGSEQ_OIDC_ISSUER`, or
`services.logseq-webapp.clientConfig`); desktop and Android bake it with a
`clientConfig` override. `self-hosting.patch`, applied to every client build,
makes `frontend/config.cljs` read it (and every other identity and endpoint
value) from `window.LOGSEQ_CONFIG`, set by `js/logseq-config.js` before any
bundle loads. Every endpoint comes from the provider's standard discovery
document, `<issuer>/.well-known/openid-configuration`, so nothing has to be
rewritten or proxied in front of it.

**Sign-in.** All Cognito coupling in the login UI sits behind `window.LSAuth`
(`packages/ui/src/amplify/`), whose only consumer is
`src/main/frontend/components/user/login.cljs`; that now passes `oidcIssuer`
through. `LoginForm` becomes an OAuth 2.0 Device Authorization Grant (RFC 8628):

1. Read `device_authorization_endpoint` and `token_endpoint` from discovery.
2. POST the device endpoint (`client_id`, `scope=openid email profile`).
3. Show `user_code` and a link to `verification_uri_complete`, which the user
   opens in any browser. Password, MFA, brokering and sign-up all happen there.
4. Poll the token endpoint with the device-code grant, honouring `interval`
   and `slow_down`, and stop if the dialog closes.
5. Hand the tokens to `userSessionRender` in the shape `login-callback`
   (`src/main/frontend/handler/user.cljs`) destructures. Unlike upstream's, the
   session carries the refresh token itself: `logged-in?` keys off it, and there
   is no Cognito localStorage entry for `auto-fill-refresh-token-from-cognito!`
   to scrape it from.

**Refresh.** Upstream refreshes in two places, both with Cognito's layout
hardcoded (`https://<oauthDomain>/oauth2/token`):

- The main thread (`<refresh-tokens` in `handler/user.cljs`). The patch has it
  resolve the endpoint once (`<token-url`: the provider's `token_endpoint` from
  discovery, or Cognito's URL when no issuer is configured) and cache it in
  `:auth/oauth-token-url`. It warms that cache whenever a full token set
  arrives (sign-in, or a restore at startup), not just on the first refresh.
- The db worker (`oauth-token-url` in `worker/sync/auth.cljs`), for its
  websocket token. It already preferred `:auth/oauth-token-url`, which the main
  thread's `sync-app-state` passes through. The patch removes its fallback of
  guessing `https://<oauth-domain>/oauth2/token`: a worker refresh before
  discovery would otherwise send the refresh token to Amazon's Cognito.

Nothing else downstream changes: `set-tokens!`, localStorage and the servers
were already provider-neutral.

Without an `oidcIssuer`, the patched client runs upstream's Cognito login and
refresh unchanged (the endpoint cache then just holds Cognito's URL), so one
generic build serves both.

### Why this mechanism (chosen 2026-09-28)

- **No usable "Cognito-compatible" IdP exists.** cognito-local supports only
  `USER_PASSWORD_AUTH`, while Amplify's `signIn` defaults to SRP, and it calls
  itself a dev emulator. moto implements `USER_SRP_AUTH`, but its
  `respond_to_auth_challenge` only checks that `PASSWORD_CLAIM_SIGNATURE` is
  non-empty, so *any* password logs anyone in (read in its source).
  LocalStack's Cognito is paid, and still an emulator. Any of them would also
  need Cognito's hosted-UI `/oauth2/token`, which the client's refresh calls.
  Amplify 6.19.1 does honour `userPoolEndpoint`, so reaching one was never the
  obstacle.
- **Password grant** would keep the in-app form, but it works only with IdPs
  that allow it: no brokering, no IdP-side MFA.
- **Redirect + PKCE** needs a separate patch per platform. Electron's
  `will-navigate` handler sends every https navigation to the system browser,
  so an in-window redirect never returns; Android needs a `logseq://` deep
  link; the web needs a callback page.
- **Device flow** runs the login on the IdP's own pages in a real browser, so
  one code path covers all three. Its only UX cost is confirming a code.
- **Discovery, not path conventions.** The first version of the patch took a
  host and mirrored Cognito's layout (`/oauth2/device` next to upstream's
  `/oauth2/token`), which forced every deployment to proxy-rewrite both paths
  onto the provider's real ones. RFC 8628 fixes no path; the discovery
  document is where a provider publishes them.
- **Runtime config, not compiled-in literals.** The values used to be
  substituted into the sources at build time, so trying another provider meant
  an 18-minute rebuild, and a container user had to rebuild the image with Nix.
  Now one generic bundle (and image) takes them from `LOGSEQ_*` at startup.
  Desktop and Android still bake theirs, having no server to ask.

The provider side, as `examples/keycloak.nix` + `examples/logseq-realm.json` do
it: the device grant enabled on a public client (`attributes`), CORS for the
app origins (`webOrigins`), and the audience mapper and `cognito:username` claim
(see `AGENTS.md`). Keycloak serves discovery with CORS itself, for any origin.

And `apiDomain` points at wherever the web app is served, because its nginx
answers `POST /file-sync/user_info` with `{"UserGroups":["rtc_2025_07_10"]}`.

## `user_info`: why the stub, and the proof

`:user/fetch-info-and-graphs` (`src/main/frontend/handler/events/ui.cljs:446`)
does nothing unless `<user-info` returns a map, and reads only `:UserGroups`.
`rtc_2025_07_10` satisfies `rtc-group?` (`handler/user.cljs:359`) even when no
`sync-server-url` is set in localStorage, which is the case for a preconfigured
build. The stub is static and the same for everyone because it grants nothing:
the sync server does its own auth.

Run both ways on 2026-09-28, same VM as `checks.login`:

- **With the stub:** `POST /file-sync/user_info` 200, then `GET /graphs` 200
  and `GET /e2ee/user-keys` 200 at the sync server.
- **Stub down (502):** sign-in completes and the refresh token is stored, but
  in 2 minutes the only requests are two `user_info` 502s. `/graphs` is never
  requested.

## Not verified

- **Desktop (Electron) and Android at runtime.** Same compiled code. The
  differences are the origin (`lsp://logseq.com`, Capacitor's
  `http://localhost`, both covered by `webOrigins: ["*"]`) and how the
  verification link opens: Electron's `setWindowOpenHandler`
  (`src/electron/electron/window.cljs`) sends https to the system browser, and
  Capacitor opens external navigation there too. Read from source, not run.
- **The db worker's refresh.** It only runs when the worker's own websocket
  token has expired, which `checks.login` never waits for. The change there is
  a one-line narrowing (drop the Cognito guess), read against the source.
- **`logseq login` (the CLI).** It is auth-code + PKCE against
  `https://<OAUTH-DOMAIN>/oauth2/authorize` with its own
  `CLI-COGNITO-CLIENT-ID` (`src/main/logseq/cli/auth.cljs`); not patched.
  Since the desktop app writes its tokens to the `~/logseq/auth.json` the CLI
  reads, don't use the CLI with a self-hosted-IdP build: it would try to
  refresh them at Cognito.
- **Sign-out** clears the app's tokens but not the IdP's session cookie.

## Traps

- **The web app routes by fragment** (`frontend/core.cljs`: reitit
  `:use-fragment`). The login page is `#/login`, not `/login`. On first start
  the app also creates the Demo graph and routes home, so a test has to ask
  for `#/login` again until it sticks.
- **nginx picks the listen socket before `server_name`.** One vhost on
  `127.0.0.1:443` and others on `0.0.0.0:443` means everything sent to
  127.0.0.1 lands on the first, whatever its Host. The symptom was a 405 on
  the `user_info` preflight.
- **Keycloak 26's device page** has a relative form `action`, and after
  `?user_code=` it goes straight to login, then a consent page, then "Device
  Login Successful". Scripted form posts have to resolve the action and carry
  every named input, not just the hidden ones.
- **Discovery is fetched without credentials** (`:with-credentials? false` in
  the patch). A provider may answer it with `Access-Control-Allow-Origin: *`,
  which browsers refuse for a credentialed request. Keycloak instead reflects
  any origin for it (it's public metadata; probed live), so `webOrigins` only
  gates the device and token endpoints.
- **The issuer's scheme is the provider's, not the client's.** The patch no
  longer prefixes `https://`, so a plain-http issuer works from an http page
  (e.g. a local test on `http://localhost`). From a secure page (any https
  deployment, and desktop's `lsp://`, which is registered secure) it would be
  blocked as mixed content, unless it's `http://localhost` itself.
- **Don't add a runtime config path for sync/publish endpoints.** Upstream
  already has one (localStorage + Settings).
- **`nginx`'s `mime.types` has no `.mjs`.** It served the PDF viewer's module
  script as `text/plain`, which browsers refuse. Found in `checks.login`'s
  console output; fixed in the recipe.
