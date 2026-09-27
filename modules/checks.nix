# One check per target — the hand-run smoke tests that verified each package
# originally, made permanent. They are deliberately shallow: reachability and
# authentication, not feature coverage. Three boot a VM because the thing under
# test answers on a port; the desktop app and the APK get plain derivations,
# because there is nothing to knock on.
{
  lib,
  inputs,
  config,
  ...
}:
let
  # Captured from the top-level (flake-wide) config, not the per-system one
  # `perSystem` binds below (which shadows `config` with its own, unrelated
  # per-system attrset) — the four services.logseq-* modules registered in
  # modules/nixos/*.nix.
  nixosModules = config.flake.nixosModules;
in
{
  perSystem =
    { pkgs, config, ... }:
    let
      # Whatever this system actually builds; the Android package only exists
      # on x86_64-linux, so only that system gets an Android check.
      packages = config.packages;

      # The endpoints the build patches into the client bundles, taken from
      # the same attrset the packages read, so a changed default cannot
      # silently diverge from what the checks assert.
      endpoints = (pkgs.callPackage ./packages/_common.nix { inherit inputs; }).defaultClientConfig;

      keycloakPort = 8080;
      syncPort = 3000;
      # publishPort is 8787, sync-worker's own canonical default — pick a
      # different port for it on this shared test node, same reasoning as
      # syncPort above (test-node collision avoidance, not a recommendation).
      syncWorkerPort = 8788;
      publishPort = 8787;
      oauthProxyPort = 9090;

      # One node definition for all three server checks: ../examples/keycloak.nix
      # describes the whole self-hosted stack (realm + sync + sync-worker +
      # publish), so each check boots it and asserts only about its own
      # target. The system closure is built once; only the boot happens
      # three times.
      stack = {
        imports = [
          (import ../examples/keycloak.nix {
            inherit (nixosModules) logseq-sync logseq-sync-worker logseq-publish;
            inherit
              keycloakPort
              syncPort
              syncWorkerPort
              publishPort
              oauthProxyPort
              ;
          })
        ];
        # Keycloak is a JVM with a PostgreSQL beside it.
        virtualisation.memorySize = 2560;
        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
        ];
      };
    in
    {
      checks = {
        # The sync server against a self-hosted Keycloak realm — the claim this
        # whole project rests on (nothing hardwired to upstream's Cognito pool),
        # and the only place it is actually proven end to end. The node's entire
        # configuration is the copyable example in ../examples/keycloak.nix.
        sync = pkgs.testers.runNixOSTest {
          name = "logseq-sync";

          nodes.machine = stack;

          testScript = ''
            machine.wait_for_unit("keycloak.service")
            machine.wait_for_open_port(${toString keycloakPort})
            machine.wait_for_unit("logseq-sync.service")
            machine.wait_for_open_port(${toString syncPort})

            # Serving, and /health needs no credentials.
            machine.succeed("""curl -sSf http://localhost:${toString syncPort}/health | grep -q '"ok":true'""")

            # Everything else does.
            machine.succeed(
                "[ 401 = $(curl -so /dev/null -w %{http_code} http://localhost:${toString syncPort}/graphs) ]"
            )

            # And a token minted by the self-hosted IdP gets in: issuer, audience,
            # expiry and RS256 signature all check out against Keycloak's JWKS.
            token = machine.succeed(
                "curl -sSf -d grant_type=password -d client_id=logseq"
                " -d username=test -d password=test"
                " http://localhost:${toString keycloakPort}/realms/logseq/protocol/openid-connect/token"
                " | jq -er .access_token"
            ).strip()
            machine.succeed(
                f"[ 200 = $(curl -so /dev/null -w %{{http_code}}"
                f" -H 'Authorization: Bearer {token}' http://localhost:${toString syncPort}/graphs) ]"
            )

            # The other half of the same realm's contract: what the *clients* read.
            # Nothing here is Logseq-specific except the claim names, but each one
            # is a thing that silently degrades rather than failing loudly, so it is
            # cheaper to assert than to debug.
            import base64
            import json as jsonlib

            def claims(jwt):
                payload = jwt.split(".")[1]
                return jsonlib.loads(
                    base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
                )

            body = jsonlib.loads(
                machine.succeed(
                    "curl -sSf -d grant_type=password -d client_id=logseq -d scope=openid"
                    " -d username=test -d password=test"
                    " http://localhost:${toString keycloakPort}/realms/logseq/protocol/openid-connect/token"
                )
            )
            # restore-tokens-from-localstorage needs all three, and gates being
            # logged in on the refresh token specifically.
            for key in ["id_token", "access_token", "refresh_token"]:
                assert key in body, f"token response has no {key}: {sorted(body)}"

            # Exactly the claims frontend/handler/user.cljs reads off the id token.
            # `cognito:username` is a Cognito-shaped name that only exists here
            # because logseq-realm.json maps it; Keycloak treats "." in a claim name
            # as nesting but ":" as literal, which is what makes that possible.
            id_claims = claims(body["id_token"])
            for claim in ["exp", "sub", "email", "cognito:username"]:
                assert claim in id_claims, f"id_token is missing {claim}"
            assert id_claims["cognito:username"] == "test", id_claims["cognito:username"]

            # And the refresh grant the client actually sends, through the rewrite
            # that exists because the client hardcodes the /oauth2/token path.
            refreshed = jsonlib.loads(
                machine.succeed(
                    "curl -sSf -d grant_type=refresh_token -d client_id=logseq"
                    f" -d refresh_token={body['refresh_token']}"
                    " http://127.0.0.1:${toString oauthProxyPort}/oauth2/token"
                )
            )
            for key in ["id_token", "access_token"]:
                assert key in refreshed, f"refresh response has no {key}"
            assert "cognito:username" in claims(refreshed["id_token"])
          '';
        };

        # The sync *worker* — deps/db-sync's Cloudflare Worker build — against
        # the same realm. Same auth contract as `sync` (it's the same base
        # sync protocol underneath), plus proof the semantic REST/MCP layer
        # and the D1 migration step both actually work: entirely untested
        # before this check existed.
        sync-worker = pkgs.testers.runNixOSTest {
          name = "logseq-sync-worker";

          nodes.machine = stack;

          testScript = ''
            machine.wait_for_unit("keycloak.service")
            machine.wait_for_open_port(${toString keycloakPort})
            machine.wait_for_unit("logseq-sync-worker.service")
            machine.wait_for_open_port(${toString syncWorkerPort})

            # Serving, and /health needs no credentials.
            machine.succeed("""curl -sSf http://localhost:${toString syncWorkerPort}/health | grep -q '"ok":true'""")

            # Everything else does — same contract as plain sync.
            machine.succeed(
                "[ 401 = $(curl -so /dev/null -w %{http_code} http://localhost:${toString syncWorkerPort}/graphs) ]"
            )

            # The semantic REST/OpenAPI layer sync.nix's Node adapter doesn't
            # have: proves the build:api-docs step (redocly + embed_api_docs)
            # actually produced something, not just that it didn't error.
            machine.succeed("curl -sSf http://localhost:${toString syncWorkerPort}/openapi.json | jq -e .info")

            # And a token minted by the self-hosted IdP gets *past verify-jwt*
            # — proves the D1 migration step completed too, since the unit
            # wouldn't have reached "active" (wait_for_open_port above)
            # otherwise. Deliberately not asserting 200/a graphs list here,
            # unlike sync's equivalent check — see the comment below.
            token = machine.succeed(
                "curl -sSf -d grant_type=password -d client_id=logseq"
                " -d username=test -d password=test"
                " http://localhost:${toString keycloakPort}/realms/logseq/protocol/openid-connect/token"
                " | jq -er .access_token"
            ).strip()
            response = machine.succeed(
                f"curl -s -H 'Authorization: Bearer {token}' http://localhost:${toString syncWorkerPort}/graphs"
            )
            assert '"error":"unauthorized"' not in response, (
                f"a realm-minted token was rejected: {response}"
            )
            # A real, understood upstream bug found here, not a packaging
            # issue — documented in AGENTS.md/memory, not fixed (out of
            # scope: patching upstream ClojureScript app logic, as opposed
            # to the packaging-level source patches this project already
            # does). deps/db-sync's <user-upsert!> (src/logseq/db_sync/
            # index.cljs) runs on every authenticated request and passes
            # `(aget claims "cognito:username")` straight to D1's .bind()
            # with no nil-coercion — unlike the adjacent email-verified
            # field, which does get coerced. The Node adapter never hits
            # this: better-sqlite3 accepts an `undefined` bind leniently;
            # D1 rejects it outright with D1_TYPE_ERROR. Keycloak, like
            # real Cognito, only puts cognito:username on the id token, not
            # the access token used here for Bearer auth (confirmed by
            # decoding this exact token) — so this reproduces against a
            # real Cognito pool too, not just a self-hosted realm.
            assert '"debug-message":"D1_TYPE_ERROR' in response, (
                f"expected the known cognito:username/D1 upstream bug (see comment), got: {response}"
            )
          '';
        };

        # The publish service, against the same self-hosted realm. Its own claim on
        # top of sync's: the worker runs at all outside Cloudflare — the Durable
        # Object and R2 bindings it stores page metadata and blobs in come from
        # wrangler's local runtime — and it reads its identity config off the
        # process environment rather than the [vars] block stripped from
        # upstream's wrangler.toml.
        publish = pkgs.testers.runNixOSTest {
          name = "logseq-publish";

          nodes.machine = stack;

          testScript = ''
            machine.wait_for_unit("keycloak.service")
            machine.wait_for_open_port(${toString keycloakPort})
            machine.wait_for_unit("logseq-publish.service")
            machine.wait_for_open_port(${toString publishPort})

            # Serving, and rendering: the home page comes out of render.cljs and the
            # static assets out of resources shadow-cljs inlined into the bundle.
            machine.succeed(
                "curl -sSf http://localhost:${toString publishPort}/ | grep -q '<title>Logseq Publish'"
            )
            machine.succeed("curl -sSf -o /dev/null http://localhost:${toString publishPort}/static/publish.js")

            # Touching a published page needs a token. DELETE rather than POST
            # because it takes no payload, so the only thing under test is auth.
            def delete_page(auth=""):
                return machine.succeed(
                    "curl -so /dev/null -w %{http_code} -X DELETE " + auth
                    + " http://localhost:${toString publishPort}/pages/no-such-graph/no-such-page"
                ).strip()

            code = delete_page()
            assert code == "401", f"unauthenticated DELETE returned {code}, not 401"

            # And a token minted by the self-hosted realm gets past verify-jwt —
            # which also means the worker reached the realm's JWKS endpoint from
            # inside workerd. 404, because the page it would delete is not there.
            token = machine.succeed(
                "curl -sSf -d grant_type=password -d client_id=logseq"
                " -d username=test -d password=test"
                " http://localhost:${toString keycloakPort}/realms/logseq/protocol/openid-connect/token"
                " | jq -er .access_token"
            ).strip()
            code = delete_page(f"-H 'Authorization: Bearer {token}'")
            assert code == "404", f"authenticated DELETE returned {code}, not 404"
          '';
        };

        # The web app is a static tree with relative asset paths, so "does it work"
        # means: point any plain file server at it and the app's entry point loads.
        webapp = pkgs.testers.runNixOSTest {
          name = "logseq-webapp";

          nodes.machine = {
            services.nginx = {
              enable = true;
              virtualHosts."localhost".root = "${packages.logseq-webapp}/share/logseq-webapp";
            };
            environment.systemPackages = [ pkgs.curl ];
          };

          testScript = ''
            machine.wait_for_unit("nginx.service")
            machine.wait_for_open_port(80)
            machine.succeed("curl -sSf http://localhost/ | grep -q '<title>Logseq'")
            # index.html pulls in ./js/main.js; if that 404s the app is a blank page.
            machine.succeed("curl -sSf -o /dev/null http://localhost/js/main.js")
          '';
        };

        # services.logseq-webapp — deliberately separate from `webapp` above,
        # which proves a different, more general claim ("any plain file
        # server can serve this bundle"). This one proves the *module*: its
        # own dedicated nginx process (not services.nginx), DynamicUser, and
        # serviceName all actually wire together, plus the wasm mime type and
        # SPA fallback _webapp-nginx.nix promises survive being run through
        # this module rather than the container image or `nix run` wrapper.
        webapp-service = pkgs.testers.runNixOSTest {
          name = "logseq-webapp-service";

          nodes.machine = {
            imports = [ nixosModules.logseq-webapp ];
            services.logseq-webapp.enable = true;
            environment.systemPackages = [ pkgs.curl ];
          };

          testScript = ''
            machine.wait_for_unit("logseq-webapp.service")
            machine.wait_for_open_port(8080)

            machine.succeed("curl -sSf http://localhost:8080/ | grep -q '<title>Logseq'")

            def content_type(path):
                return machine.succeed(
                    f"curl -sSf -o /dev/null -w %{{content_type}} http://localhost:8080/{path}"
                ).strip()

            assert content_type("js/sqlite3.wasm") == "application/wasm"

            code = machine.succeed(
                "curl -so /dev/null -w %{http_code} http://localhost:8080/login"
            ).strip()
            assert code == "200", f"SPA fallback returned {code}"
          '';
        };

        # The container images. Only the web app's gets a check: it is the one
        # with logic of its own (an nginx config that has to serve
        # application/wasm for sqlite3.wasm and fall back to index.html for
        # client-side routes, from an unprivileged process). The sync and
        # publish images are thin wrappers around packages `sync`/`publish`
        # already cover, and the publish image is ~2.6GB, which is a lot of VM
        # disk for "the binary we already tested still starts".
        containers = pkgs.testers.runNixOSTest {
          name = "logseq-containers";

          nodes.machine = {
            virtualisation.oci-containers = {
              backend = "podman";
              containers.logseq-webapp = {
                imageFile = packages.logseq-webapp-image;
                image = "logseq-webapp:latest";
                ports = [ "8080:8080" ];
                # Same shape as examples/docker-compose.yml: nginx cannot setuid
                # with no capabilities, so it starts unprivileged instead.
                extraOptions = [
                  "--user=65534:65534"
                  "--cap-drop=ALL"
                  "--security-opt=no-new-privileges=true"
                ];
              };
            };
            # Loading a layered image and running podman needs room.
            virtualisation.diskSize = 4096;
            environment.systemPackages = [ pkgs.curl ];
          };

          testScript = ''
            machine.wait_for_unit("podman-logseq-webapp.service")
            machine.wait_for_open_port(8080)

            machine.succeed("curl -sSf http://localhost:8080/ | grep -q '<title>Logseq'")

            def content_type(path):
                return machine.succeed(
                    f"curl -sSf -o /dev/null -w %{{content_type}} http://localhost:8080/{path}"
                ).strip()

            # The browser refuses to instantiate sqlite3.wasm as anything else,
            # and a wrong type here is invisible until the DB worker dies.
            assert content_type("js/sqlite3.wasm") == "application/wasm"
            assert content_type("js/main.js").startswith("application/javascript")

            # frontend/routes.cljs uses real paths, so a reload on /login has to
            # reach index.html rather than 404.
            code = machine.succeed(
                "curl -so /dev/null -w %{http_code} http://localhost:8080/login"
            ).strip()
            assert code == "200", f"SPA fallback returned {code}"
          '';
        };

        # No port to knock on, so check what a desktop install has to get right:
        # the launcher runs, the window manager can match the icon, and both halves
        # of the endpoint patching (ClojureScript bundle and OCaml CLI bundle, which
        # are substituted separately) actually landed.
        desktop =
          pkgs.runCommand "logseq-desktop-check"
            {
              nativeBuildInputs = [ pkgs.nodejs ];
            }
            ''
              app=${packages.logseq}

              test -x "$app/bin/logseq"

              # StartupWMClass must stay in sync with the wrapper's --class=Logseq,
              # or the taskbar shows a generic icon while the app picker looks fine.
              grep -q '^StartupWMClass=Logseq$' "$app/share/applications/Logseq.desktop"

              # The CLI half runs headless, so actually run it.
              node "$app/share/logseq/logseq-cli.js" --help | grep -q '^Usage: logseq'

              grep -q '${endpoints.apiDomain}' "$app/share/logseq/js/main.js"
              grep -q '${endpoints.syncHttpBase}' "$app/share/logseq/logseq-cli.js"

              touch $out
            '';

        # `nix flake check` already type-checks nixosModules.logseq for free
        # (the "checking NixOS module" step) — this goes one step further and
        # proves `enable` actually does something: evaluate a throwaway
        # nixosSystem with it, assert the package landed in
        # environment.systemPackages. Eval-only, no VM: cheap, and there is
        # nothing here that answers on a port to boot one for.
        desktop-module =
          let
            testSystem = inputs.nixpkgs.lib.nixosSystem {
              inherit (pkgs.stdenv.hostPlatform) system;
              inherit pkgs;
              modules = [
                nixosModules.logseq
                { programs.logseq.enable = true; }
              ];
            };
          in
          assert lib.assertMsg (builtins.elem packages.logseq testSystem.config.environment.systemPackages)
            "programs.logseq.enable did not add packages.logseq to environment.systemPackages";
          pkgs.runCommand "logseq-nixos-module-check" { } "touch $out";
      }
      // lib.optionalAttrs (packages ? logseq-android) {
        # An ordinary derivation since Milestone 2 (gradle.fetchDeps), same as
        # every other target — still worth its own check: did the build
        # produce a real APK, and did the client config reach the web assets
        # Capacitor ships inside it.
        android =
          pkgs.runCommand "logseq-android-check"
            {
              nativeBuildInputs = [ pkgs.unzip ];
            }
            ''
              apk=${packages.logseq-android}/app-release-unsigned.apk

              for entry in AndroidManifest.xml classes.dex resources.arsc; do
                unzip -l "$apk" "$entry" | grep -q "$entry"
              done

              unzip -p "$apk" assets/public/js/main.js | grep -q '${endpoints.apiDomain}'

              touch $out
            '';
      };
    };
}
