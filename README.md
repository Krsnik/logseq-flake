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
| `logseq-{webapp,sync,publish}-image` | Container images of the three deployable targets                                                                             |
| `logseq-webapp-docker-image`         | The webapp image, configurable via `docker build --build-arg` — no Nix required                                              |

Every server/webapp target is also runnable directly with no install step:

```sh
nix run path:.#logseq-{webapp,sync,sync-worker,publish}
```

## Using the packages

The three client targets (`logseq`, `logseq-webapp`, `logseq-android`) take a `clientConfig` override to create a build with your own endpoints:

```nix
inputs.logseq.packages.${system}.logseq-webapp.override {
  clientConfig = {
    apiDomain = "api.example.org";
    syncHttpBase = "https://sync.example.org";
    syncWsUrl = "wss://sync.example.org/sync/%s";
    publishApiBase = "https://blog.example.org";
  };
}
```

| `clientConfig` key           | Sets                                                                         |
| ---------------------------- | ---------------------------------------------------------------------------- |
| `apiDomain`                  | Host answering `/file-sync/user_info`; point it at your web app              |
| `oauthDomain`                | Identity-provider host used for login                                        |
| `cognitoClientId`            | OAuth client id                                                              |
| `cognitoIdp`                 | Identity-provider issuer URL                                                 |
| `userPoolId`                 | Cognito-shaped user-pool id                                                  |
| `syncHttpBase` / `syncWsUrl` | Default sync server URL (`%s` is the graph id) — a *default* only, see below |
| `publishApiBase`             | Default publish server URL — also a default only                             |
| `oidcDeviceFlow`             | `true` replaces the Cognito login form with the OAuth device flow (see below) |

`logseq-sync`, `logseq-sync-worker` and `logseq-publish` take no `clientConfig` —
see [Setting the identity provider](#setting-the-identity-provider) for how they're configured instead.

## Using the container images

```sh
nix build path:.#logseq-sync-image && podman load -i result
```

`examples/docker-compose.yml` wires the web app, sync and publish images together on ports 8080/8081/8082 (`docker compose` and `podman-compose` alike) —
copy it, set the three `LOGSEQ_OIDC_*` variables (no defaults on purpose) and `docker compose up -d`. The web app's endpoints are compiled in,
so to brand that one image, rebuild it with `clientConfig` as above:

```nix
logseq-webapp-image.override { clientConfig.apiDomain = "api.example.org"; }
```

Or skip Nix entirely with `logseq-webapp-docker-image`,
which reads its `clientConfig` from `examples/docker-build/client-config.json` and exposes it as `docker build --build-arg`s:

```sh
podman build --network host -o type=local,dest=out \
  --build-arg API_DOMAIN=api.example.org \
  -f examples/docker-build/Dockerfile .

./examples/docker-build/load-image.sh out/result
```

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
| `package`                                                       | all                        | Override for a custom `clientConfig` or build                                                                                  |
| `serviceName`                                                   | all                        | systemd unit name, for cross-referencing from another module (default `logseq-<name>`)                                         |
| `port`                                                          | all                        | Listen port                                                                                                                    |
| `openFirewall`                                                  | all                        | Open `port` in the firewall                                                                                                    |
| `user` / `group`                                                | all                        | Fixed user instead of the default `DynamicUser` (needed if your host doesn't keep a `DynamicUser`'s UID stable across reboots) |
| `oidcIssuer`                                                    | sync, sync-worker, publish | Identity-provider issuer URL (required)                                                                                        |
| `oidcClientId`                                                  | sync, sync-worker, publish | Expected client id (required)                                                                                                  |
| `oidcJwksUrl`                                                   | sync, sync-worker, publish | Signing-key endpoint (required)                                                                                                |
| `r2AccountId`, `r2Bucket`, `r2AccessKeyId`, `r2SecretAccessKey` | sync-worker, publish       | R2 binding — placeholders are fine, both run on wrangler's local runtime with no real R2 to reach                              |

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

**Clients sign in with the OAuth device flow** when built with `oidcDeviceFlow = true`.
The login dialog shows a short code and a link to your identity provider,
you log in there with whatever it offers (password, MFA, or a brokered GitLab/Forgejo login),
and the app picks up the tokens. The same code runs on web, desktop and Android:

```nix
clientConfig = {
  oidcDeviceFlow = true;
  oauthDomain = "id.example.org";   # serves /oauth2/device and /oauth2/token
  cognitoClientId = "logseq";       # your IdP's public client
  apiDomain = "notes.example.org";  # where logseq-webapp is served
  syncHttpBase = "https://sync.example.org";
  syncWsUrl = "wss://sync.example.org/sync/%s";
};
```

Your identity provider needs:

- a public client with the OAuth 2.0 device authorization grant enabled;
- `https://<oauthDomain>/oauth2/device` and `/oauth2/token` routed to its device-authorization and token endpoints,
  since the client hardcodes those Cognito-style paths (`examples/keycloak.nix` shows the two nginx locations),
  with CORS allowed for your app's origins;
- a scalar `aud` equal to the client id on the access token, and a `cognito:username` claim on the id token
  (`examples/logseq-realm.json` has both mappers).

And `apiDomain` has to answer `POST /file-sync/user_info` with `{"UserGroups":["rtc_2025_07_10"]}`.
Without it the app signs in but never syncs.
The web app's image, NixOS module and `nix run` wrapper already serve exactly that, so point `apiDomain` at your web app.

Proven end to end for the web app by `checks.login`.
Desktop and Android run the same code but haven't been exercised end to end yet.
See `docs/self-hosted-identity.md` for how it works and what's left.

## More detail

`AGENTS.md` has the full internals: how each package is built, every check
`nix flake check` runs and what it proves, the repo layout, and known gaps.
