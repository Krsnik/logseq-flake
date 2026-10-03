# Example: the Logseq sync and publish servers authenticating against a
# self-hosted Keycloak realm instead of upstream's Cognito user pool.
#
# This exact module is what ../modules/checks.nix boots, so the recipe is
# verified, not aspirational. Copy both files into your configuration and
# import this one with the nixosModules:
#
#   imports = [
#     (import ./keycloak.nix {
#       inherit (inputs.logseq.nixosModules) logseq-sync logseq-publish;
#     })
#   ];
#
# Everything marked TEST-ONLY below (plaintext passwords in the world-readable
# store, plain HTTP, a localhost hostname) has to be replaced for a real
# deployment. The parts that matter — the realm in ./logseq-realm.json and the
# three oidc* options below — carry over unchanged.
{
  logseq-sync,
  logseq-publish,
  # Optional: the Cloudflare-Worker sync variant, an *alternative* to
  # logseq-sync (incompatible storage — a real deployment runs one, not
  # both). Included as an option here, rather than a second example file,
  # so ../../modules/checks.nix can verify it against this same realm
  # without duplicating the Keycloak setup below.
  logseq-sync-worker ? null,
  keycloakPort ? 8080,
  # This example's sync server sits on 3000, not the module's own canonical
  # default (8080), purely to avoid colliding with this same node's Keycloak
  # (also on 8080) — not a recommendation for real deployments.
  syncPort ? 3000,
  syncWorkerPort ? 8787,
  publishPort ? 8787,
  # Must match the realm in ./logseq-realm.json, and must equal the token's
  # `iss` claim character for character: verify-jwt compares them with =.
  issuer ? "http://localhost:${toString keycloakPort}/realms/logseq",
  clientId ? "logseq",
}:
{ pkgs, lib, ... }:
{
  imports = [
    logseq-sync
    logseq-publish
  ]
  # A plain fragment bundling the module import together with its own
  # config, not a bare `lib.optional (...) logseq-sync-worker`: setting
  # `services.logseq-sync-worker` further down would be an "option does not
  # exist" error whenever this whole thing is left out (module not
  # imported), regardless of any mkIf around the value — so the option's
  # declaration and its definition have to travel together as one unit.
  ++ lib.optional (logseq-sync-worker != null) {
    imports = [ logseq-sync-worker ];
    services.logseq-sync-worker = {
      enable = true;
      port = syncWorkerPort;
      oidcIssuer = issuer;
      oidcClientId = clientId;
      oidcJwksUrl = "${issuer}/protocol/openid-connect/certs";
    };
    systemd.services.logseq-sync-worker.after = [ "keycloak.service" ];
  };
  services.keycloak = {
    enable = true;

    # TEST-ONLY: plain HTTP on localhost. A real deployment sets a public
    # hostname and TLS (sslCertificate/sslCertificateKey, or a reverse proxy
    # plus proxy-headers) — and `issuer` above must follow it.
    settings = {
      hostname = "http://localhost:${toString keycloakPort}";
      http-enabled = true;
      http-port = keycloakPort;
    };

    # TEST-ONLY: real secrets belong in a file outside the Nix store.
    initialAdminPassword = "admin";
    database.passwordFile = toString (pkgs.writeText "kc-db-password" "keycloak");

    # Imported on first start only; later edits need the admin console or
    # kcadm, not a rebuild. A path literal, not pkgs.writeText: the module
    # derives a tmpfiles target from the file's basename, and a generated
    # file's basename carries store-path context that tmpfiles rejects.
    #
    # Two things in that realm are load-bearing, and both are there because
    # verify-jwt reads `(or aud client_id)` and needs the result to be a
    # *string* equal to COGNITO_CLIENT_ID (deps/common/src/logseq/common/
    # authorization.cljs, client-id-allowed?). A stock Keycloak access token
    # has neither claim in that shape — there is no `client_id` (it is `azp`),
    # and `aud` is whatever the "audience resolve" mapper in the built-in
    # `roles` scope collected, usually the array ["account"]. So the client
    # carries an oidc-audience-mapper naming itself, *and* drops `roles` from
    # its default scopes so nothing else lands in `aud`. One audience left,
    # which Keycloak serialises as a scalar: "aud": "logseq".
    #
    # The sync worker's REST API and MCP server also want `logseq/read` and
    # `logseq/write` in the access token's `scope`, so the realm declares
    # them as client scopes. Declaring any stops Keycloak from creating its
    # built-in ones, hence `basic`/`profile`/`email` alongside, carrying
    # only the claims Logseq reads — and `offline_access`, which the apps
    # request at sign-in so their refresh token outlives the SSO session
    # (30 minutes idle by default): an offline session idles out after 30
    # days unused instead, and every refresh renews it. Each user needs the
    # `offline_access` role in `realmRoles`: Keycloak rejects the grant with a
    # `not_allowed` that carries no CORS headers (the app sees "Failed to
    # fetch"), and an import ignores composites given in `defaultRole`.
    #
    # The test user also needs firstName/lastName: without them Keycloak's
    # VERIFY_PROFILE required action blocks every login with
    # "Account is not fully set up".
    realmFiles = [ ./logseq-realm.json ];
  };

  # Clients need nothing in front of the realm: given this same `issuer` as
  # their `oidcIssuer` (LOGSEQ_OIDC_ISSUER for the web app), they read the
  # device authorization and token endpoints from its discovery document
  # (../modules/packages/self-hosting.patch). The realm client only needs
  # the device grant switched on (logseq-realm.json's `attributes`) —
  # verified by the `login` check.

  # Both servers take all of their identity config from the environment —
  # nothing is baked into either package — so switching identity providers is
  # these three values. The COGNITO_* wire names are upstream's and carry no
  # Amazon semantics: issuer, client id and JWKS endpoint of any OIDC
  # provider; the modules expose them as oidc* options and map them
  # internally. Published pages and assets are served by the publish worker
  # itself; the R2 placeholders (module defaults, not set here) keep its
  # presigned-URL signing code happy against a local workerd runtime with no
  # real R2 endpoint to reach — same as the existing container deployment.
  services.logseq-sync = {
    enable = true;
    port = syncPort;
    oidcIssuer = issuer;
    oidcClientId = clientId;
    oidcJwksUrl = "${issuer}/protocol/openid-connect/certs";
  };

  services.logseq-publish = {
    enable = true;
    port = publishPort;
    oidcIssuer = issuer;
    oidcClientId = clientId;
    oidcJwksUrl = "${issuer}/protocol/openid-connect/certs";
  };

  systemd.services.logseq-sync.after = [ "keycloak.service" ];
  systemd.services.logseq-publish.after = [ "keycloak.service" ];
}
