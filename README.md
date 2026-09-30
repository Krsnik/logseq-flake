# Logseq — packaged with Nix

[Logseq](https://github.com/logseq/logseq) 2.0.1 (the DB-graph version),
built from source and packaged as a fully self-hostable stack: desktop client, web app, sync server, publish service and Android app.

Upstream hardcodes an AWS Cognito user pool for login and Cloudflare-hosted `logseq.io`/`logseq.com` for sync and publishing.
This flake makes every one of those (identity provider, sync endpoint, publish endpoint) configurable,
so a self-hosted deployment never has to talk to Amazon or Cloudflare's infrastructure.
Proven end to end against a self-hosted Keycloak realm (see [Setting the identity provider](#setting-the-identity-provider) below).

## What's bundled

| Package                              | What it is                                                                                                                   |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `logseq`                             | Desktop client (Electron) + bundled CLI                                                                                      |
| `logseq-webapp`                      | Static PWA bundle; servable from any file root                                                                               |
| `logseq-android`                     | Unsigned APK                                                                                                                 |
| `logseq-sync`                        | Sync server (Node adapter)                                                                                                   |
| `logseq-sync-worker`                 | Sync server, Cloudflare Worker build (REST/MCP/ChatGPT-Apps; **not** interchangeable with `logseq-sync` — different storage) |
| `logseq-publish`                     | Publish service (Worker on wrangler's local runtime)                                                                         |
| `logseq-{webapp,sync,publish}-image` | Container images of the three deployable targets, configured from the environment                                            |

Every server/webapp target is also runnable directly with no install step:

```sh
nix run path:.#logseq-{webapp,sync,sync-worker,publish}
```

## Using the packages

The clients read their identity provider and endpoints (`clientConfig`) at runtime, from `js/logseq-config.js`;
anything unset falls back to upstream's values. So the web app is a generic build, configured when it's deployed:
environment variables for the container image and `nix run`, `services.logseq-webapp.clientConfig` for the NixOS module.
No rebuild to try a different identity provider:

```sh
LOGSEQ_OIDC_ISSUER=https://id.example.org/realms/logseq LOGSEQ_OIDC_CLIENT_ID=logseq \
  nix run path:.#logseq-webapp
```

Desktop and Android have no server to hand them config, so they bake it in with an override
(on the web app, the same override only sets the defaults the environment can still change):

```nix
inputs.logseq.packages.${system}.logseq.override {
  clientConfig = {
    oidcIssuer = "https://id.example.org/realms/logseq";
    cognitoClientId = "logseq";
    apiDomain = "notes.example.org";
    syncUrl = "https://sync.example.org";
    publishUrl = "https://blog.example.org";
  };
}
```

| `clientConfig` key           | Environment variable                                   | Sets                                                                   |
| ---------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------- |
| `oidcIssuer`                 | `LOGSEQ_OIDC_ISSUER`                                   | Your OIDC provider; replaces Cognito login and refresh (see below)     |
| `cognitoClientId`            | `LOGSEQ_OIDC_CLIENT_ID`                                | OAuth client id                                                        |
| `apiDomain`                  | `LOGSEQ_API_DOMAIN`                                    | Host answering `/file-sync/user_info`; point it at your web app        |
| `syncUrl`                    | `LOGSEQ_SYNC_URL`                                      | Default sync server (`https://host`); users can still change it        |
| `publishUrl`                 | `LOGSEQ_PUBLISH_URL`                                   | Default publish server, likewise                                       |
| `oauthDomain`                | `LOGSEQ_COGNITO_OAUTH_DOMAIN`                          | Cognito hosted-login host (upstream's login only)                      |
| `cognitoIdp` / `userPoolId`  | `LOGSEQ_COGNITO_IDP` / `LOGSEQ_COGNITO_USER_POOL_ID`   | Cognito API endpoint and user pool (upstream's login only)             |

`logseq-sync`, `logseq-sync-worker` and `logseq-publish` take no `clientConfig` —
see [Setting the identity provider](#setting-the-identity-provider) for how they're configured instead.

## Using the container images

```sh
nix build path:.#logseq-webapp-image && podman load -i result
```

All three images are generic and configured from the environment, so they can be built once and published.
`examples/docker-compose.yml` wires the web app, sync and publish images together on ports 8080/8081/8082
(`docker compose` and `podman-compose` alike): copy it, fill in the `LOGSEQ_*` variables listed at its top
(no defaults on purpose) and `docker compose up -d`.

## Using the NixOS modules

One module per server/webapp target, `inputs.logseq.nixosModules.logseq-{webapp,sync,sync-worker,publish}`:

```nix
{
  imports = [ inputs.logseq.nixosModules.logseq-sync ];
  services.logseq-sync = {
    enable = true;
    oidcIssuer = "https://idp.example.org/realms/logseq";
    oidcClientId = "logseq";
    oidcJwksUrl = "https://idp.example.org/realms/logseq/protocol/openid-connect/certs";
  };
}
```

| Option                                                          | Modules                    | Meaning                                                                                                                        |
| --------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `enable`                                                        | all                        | Turn the service on                                                                                                            |
| `package`                                                       | all                        | Override for a custom build                                                                                                    |
| `serviceName`                                                   | all                        | systemd unit name, for cross-referencing from another module (default `logseq-<name>`)                                         |
| `port`                                                          | all                        | Listen port                                                                                                                    |
| `openFirewall`                                                  | all                        | Open `port` in the firewall                                                                                                    |
| `user` / `group`                                                | all                        | Fixed user instead of the default `DynamicUser` (needed if your host doesn't keep a `DynamicUser`'s UID stable across reboots) |
| `clientConfig`                                                  | webapp                     | The web app's `clientConfig` (keys above), served at runtime: changing it restarts nginx, it doesn't rebuild the bundle        |
| `oidcIssuer`                                                    | sync, sync-worker, publish | Identity-provider issuer URL (required)                                                                                        |
| `oidcClientId`                                                  | sync, sync-worker, publish | Expected client id (required)                                                                                                  |
| `oidcJwksUrl`                                                   | sync, sync-worker, publish | Signing-key endpoint (required)                                                                                                |
| `r2AccountId`, `r2Bucket`, `r2AccessKeyId`, `r2SecretAccessKey` | sync-worker, publish       | R2 binding — placeholders are fine, both run on wrangler's local runtime with no real R2 to reach                              |
| `dataDir`                                                       | sync, sync-worker, publish | Data directory (default `/var/lib/<serviceName>`); under `/var/lib`, nested paths included, systemd creates it for `user`   |
| `publicUrl`                                                     | sync-worker                | The URL clients reach it at behind a reverse proxy (`SYNC_WORKER_PUBLIC_URL`); MCP clients need it                            |

`services.logseq-webapp` runs its own dedicated nginx (there's no backend here to proxy to); the other three own a systemd unit each.
`examples/keycloak.nix` shows all of these wired up against a self-hosted Keycloak realm.

## Using the desktop client

`inputs.logseq.nixosModules.logseq` (system-wide) and
`inputs.logseq.homeManagerModules.logseq` (per-user) both expose
`programs.logseq`:

```nix
{
  imports = [ inputs.logseq.homeManagerModules.logseq ];
  programs.logseq = {
    enable = true;
    autostart = true; # home-manager only; also needs xdg.autostart.enable
  };
}
```

| Option                          | Meaning                                                                    |
| ------------------------------- | -------------------------------------------------------------------------- |
| `enable`                        | Install the desktop client                                                 |
| `package`                       | Override for a custom `clientConfig`                                       |
| `autostart` (home-manager only) | Start on login via XDG autostart (needs `xdg.autostart.enable = true` too) |

## Setting the identity provider

**Servers accept any OIDC provider** — token verification is issuer + audience + expiry + RS256-against-JWKS, with no Cognito-specific calls.
`examples/keycloak.nix` is a complete, working self-hosted Keycloak deployment; adapt its realm export for another provider.

| Env var (or NixOS option above)      | Meaning                                                 |
| ------------------------------------ | ------------------------------------------------------- |
| `COGNITO_ISSUER` (`oidcIssuer`)      | Issuer URL; compared to the token's `iss` claim exactly |
| `COGNITO_CLIENT_ID` (`oidcClientId`) | Expected `aud`/`client_id` claim                        |
| `COGNITO_JWKS_URL` (`oidcJwksUrl`)   | Signing-key endpoint, fetched on first use and cached   |

(The `COGNITO_*` names are upstream's; they carry no Amazon-specific meaning and work with any OIDC provider.)

**Clients sign in with the OAuth device flow** once they're given an `oidcIssuer`, the same value the servers get.
The login dialog shows a short code and a link to your identity provider,
you log in there with whatever it offers (password, MFA, or a brokered GitLab/Forgejo login),
and the app picks up the tokens. The same code runs on web, desktop and Android.
For the web app that's runtime configuration, e.g. for the container image:

```sh
LOGSEQ_OIDC_ISSUER=https://id.example.org/realms/logseq  # same value as the servers' oidcIssuer
LOGSEQ_OIDC_CLIENT_ID=logseq                             # your provider's public client
LOGSEQ_API_DOMAIN=notes.example.org                      # where the web app is served
LOGSEQ_SYNC_URL=https://sync.example.org
```

(desktop and Android: the same keys as a `clientConfig` override, see [Using the packages](#using-the-packages)).

The client reads every endpoint it needs from the provider's standard discovery document
(`<oidcIssuer>/.well-known/openid-configuration`), so nothing has to be rewritten or proxied. Your provider needs:

- a public client with the OAuth 2.0 device authorization grant enabled;
- CORS allowed for your app's origins: the web app's own, `lsp://logseq.com` for desktop;
- nothing else: the clients send the id token, whose `aud` is the client id, and take the user name from
  `cognito:username` or else the standard `preferred_username`, both of which any provider puts there by default.

And `apiDomain` has to answer `POST /file-sync/user_info` with `{"UserGroups":["rtc_2025_07_10"]}`.
Without it the app signs in but never syncs.
The web app's image, NixOS module and `nix run` wrapper already serve exactly that, so point `apiDomain` at your web app.

Proven end to end for the web app by `checks.login`.
Desktop and Android run the same code but haven't been exercised end to end yet.
See `docs/self-hosted-identity.md` for how it works and what's left.

### REST API and MCP

`logseq-sync-worker` (not `logseq-sync`) also serves a REST API (docs at `/api-docs`, spec at `/openapi.json`)
and an MCP server at `/mcp`. Their clients send an access token, so the provider additionally needs:

- the access token's `aud` to be exactly the client id (Keycloak: an audience mapper, and no `roles` scope);
- `logseq/read` and `logseq/write` in its `scope` (Keycloak: two client scopes, default on the client);
- loopback redirect URIs on the client (`http://localhost:*`, `http://127.0.0.1:*`) for MCP clients to sign in with it.

`examples/logseq-realm.json` has all of it. In Keycloak, declaring any client scope in a realm import stops it
creating the built-in ones, so that realm declares `basic`, `profile` and `email` itself.
Set the module's `publicUrl` when the worker sits behind a reverse proxy. Then, reusing the realm's public client:

```sh
claude mcp add --transport http --client-id logseq --callback-port 47111 logseq https://sync.example.org/mcp
```

```json
{ "mcp": { "logseq": { "type": "remote", "url": "https://sync.example.org/mcp",
                       "oauth": { "clientId": "logseq", "scope": "logseq/read logseq/write" } } } }
```

(the second is opencode's `opencode.json`; `opencode mcp auth logseq` signs in). `checks.sync-worker` runs both
clients' sign-ins against the realm and calls the API directly and through MCP. It doesn't run the clients themselves.

## More detail

`AGENTS.md` has the full internals: how each package is built, every check
`nix flake check` runs and what it proves, the repo layout, and known gaps.
