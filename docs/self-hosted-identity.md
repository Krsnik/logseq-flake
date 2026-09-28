# Clients against a self-hosted identity provider

Status as of 2026-09-28: **done for the web app and proven end to end; built
the same way for desktop and Android, but not runtime-verified there.** File
references are to the pinned 2.0.1 source (the `logseq-src` flake input), not
to `../logseq`, which is a newer nightly with a rewritten login component.

| Piece | State | Evidence |
| - | - | - |
| Sync + publish accept any OIDC provider | done, proven | `checks.sync`, `checks.publish` |
| Token contract the clients need | done, proven | `checks.sync`: claims on the id token, refresh through the `/oauth2/token` rewrite |
| Endpoint overriding | done, mostly upstream's own | `localStorage` `sync-server-url` / `publish-server-url`; `clientConfig` supplies defaults |
| `user_info` on the critical path | done, proven load-bearing | stub in `modules/packages/_webapp-nginx.nix`; negative case below |
| Sign-in against a non-Cognito IdP | done for web, proven | `checks.login`; `modules/packages/oidc-device-flow.patch` |
| Same, desktop and Android | built, not runtime-verified | same compiled `ui.js`; see "Not verified" |

## How sign-in works

`clientConfig.oidcDeviceFlow = true` makes `applyClientConfig` apply
`oidc-device-flow.patch` to `packages/ui/src/amplify/{core.ts,ui.tsx}`. That is
the one place all Cognito coupling sits: `window.LSAuth`, whose only consumer is
`src/main/frontend/components/user/login.cljs`. `LoginForm` becomes an OAuth 2.0
Device Authorization Grant (RFC 8628):

1. POST `https://<oauthDomain>/oauth2/device` (`client_id`, `scope=openid email profile`).
2. Show `user_code` and a link to `verification_uri_complete`, which the user
   opens in any browser. Password, MFA, brokering and sign-up all happen there.
3. Poll `https://<oauthDomain>/oauth2/token` with the device-code grant,
   honouring `interval` and `slow_down`, and stop if the dialog closes.
4. Hand the tokens to `userSessionRender` in the shape `login-callback`
   (`src/main/frontend/handler/user.cljs`) destructures. Unlike upstream's, the
   session carries the refresh token itself: `logged-in?` keys off it, and there
   is no Cognito localStorage entry for `auto-fill-refresh-token-from-cognito!`
   to scrape it from.

Nothing downstream changes: `set-tokens!`, localStorage, the refresh loop and
the servers were already provider-neutral.

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

The IdP side, as `examples/keycloak.nix` + `examples/logseq-realm.json` do it:

- device grant enabled on a public client (`attributes`);
- `/oauth2/device` and `/oauth2/token` on the `oauthDomain` host, rewritten to
  the realm's endpoints (Keycloak's own CORS covers both, via `webOrigins`);
- the audience mapper and `cognito:username` claim (see `AGENTS.md`).

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
- **`logseq login` (the CLI).** It is auth-code + PKCE against
  `/oauth2/authorize` with its own `CLI-COGNITO-CLIENT-ID`
  (`src/main/logseq/cli/auth.cljs`), which `applyClientConfig` doesn't patch.
  Untouched.
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
- **`oauthDomain` sets only a host**; the paths are hardcoded (`/oauth2/token`
  for refresh, `/oauth2/device` for the patch). Without the token rewrite,
  sign-in works and the first refresh fails.
- **Don't add a runtime config path for sync/publish endpoints.** Upstream
  already has one (localStorage + Settings).
- **`nginx`'s `mime.types` has no `.mjs`.** It served the PDF viewer's module
  script as `text/plain`, which browsers refuse. Found in `checks.login`'s
  console output; fixed in the recipe.
