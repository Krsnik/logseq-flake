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

            # The claims the clients read off the id token. The user name is the
            # standard preferred_username: the patches fall back to it when
            # Cognito's cognito:username is missing, so no custom mapper.
            id_claims = claims(body["id_token"])
            for claim in ["exp", "sub", "email", "preferred_username"]:
                assert claim in id_claims, f"id_token is missing {claim}"
            assert id_claims["preferred_username"] == "test", id_claims["preferred_username"]

            # And the refresh grant the client actually sends, at the token
            # endpoint it reads from the realm's discovery document
            # (self-hosting.patch) — the same document sign-in reads the
            # device endpoint from, so assert that one is advertised too.
            discovery = jsonlib.loads(
                machine.succeed(
                    "curl -sSf http://localhost:${toString keycloakPort}/realms/logseq/.well-known/openid-configuration"
                )
            )
            assert "device_authorization_endpoint" in discovery, sorted(discovery)
            refreshed = jsonlib.loads(
                machine.succeed(
                    "curl -sSf -d grant_type=refresh_token -d client_id=logseq"
                    f" -d refresh_token={body['refresh_token']}"
                    f" {discovery['token_endpoint']}"
                )
            )
            for key in ["id_token", "access_token"]:
                assert key in refreshed, f"refresh response has no {key}"
            assert "preferred_username" in claims(refreshed["id_token"])
          '';
        };

        # The client half of the self-hosted-IdP claim, end to end, in a real
        # browser: the stock web app, given an oidcIssuer at runtime, signs in
        # through its own UI against the realm `sync` uses, refreshes its token,
        # and the sync server then receives a request carrying the token it
        # got. Everything the logged-in flow needs is on that path (the runtime
        # config, the device-flow patch and its endpoint discovery, the
        # user_info stub in _webapp-nginx.nix), so if any piece is missing, no
        # authenticated /graphs request arrives.
        login =
          let
            hosts = [
              "app.test"
              "sync.test"
            ];
            # TEST-ONLY: one self-signed cert for both, and a browser that
            # ignores it. TLS at all because the client hardcodes https:// for
            # apiDomain, and an https page cannot open a ws:// sync socket. The
            # realm itself stays plain http://localhost, which browsers treat as
            # trustworthy, so fetching it from the https page is not mixed content.
            cert = pkgs.runCommand "logseq-test-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
              mkdir $out
              openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=logseq.test \
                -addext subjectAltName=${lib.concatMapStringsSep "," (h: "DNS:${h}") hosts} \
                -keyout $out/key.pem -out $out/cert.pem
            '';
            tls = {
              onlySSL = true;
              sslCertificate = "${cert}/cert.pem";
              sslCertificateKey = "${cert}/key.pem";
            };
            webappPort = 8081;
            # Chrome DevTools Protocol, one Runtime.evaluate per call: enough to
            # click a button and read the DOM, with nothing to install.
            cdp = pkgs.writeText "cdp.mjs" ''
              const targets = await (await fetch('http://127.0.0.1:9222/json')).json()
              const ws = new WebSocket(targets.find(t => t.type === 'page').webSocketDebuggerUrl)
              await new Promise(resolve => ws.onopen = resolve)
              ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate',
                params: { expression: process.argv[2], awaitPromise: true, returnByValue: true } }))
              const { result } = await new Promise(resolve => ws.onmessage = e => resolve(JSON.parse(e.data)))
              console.log(JSON.stringify(result.result.value ?? null))
              ws.close()
            '';
          in
          pkgs.testers.runNixOSTest {
            name = "logseq-login";

            nodes.machine = {
              imports = [
                stack
                nixosModules.logseq-webapp
              ];
              # Keycloak and a browser running the whole app.
              virtualisation.memorySize = lib.mkForce 4096;
              virtualisation.cores = 4;
              networking.hosts."127.0.0.1" = hosts;
              services.nginx.enable = true;

              services.logseq-webapp = {
                enable = true;
                port = webappPort;
                # The stock package, configured at runtime: the generic build
                # a published image ships, with nothing baked in for this realm.
                clientConfig = {
                  # The realm's issuer, the same value the servers get: every
                  # endpoint the client needs is in its discovery document.
                  oidcIssuer = "http://localhost:${toString keycloakPort}/realms/logseq";
                  cognitoClientId = "logseq";
                  apiDomain = "app.test";
                  syncUrl = "https://sync.test";
                };
              };

              services.nginx.virtualHosts = {
                "app.test" = tls // {
                  locations."/".proxyPass = "http://127.0.0.1:${toString webappPort}";
                };
                "sync.test" = tls // {
                  locations."/" = {
                    proxyPass = "http://127.0.0.1:${toString syncPort}";
                    proxyWebsockets = true;
                  };
                };
              };

              environment.systemPackages = [
                pkgs.chromium
                pkgs.nodejs
              ];
            };

            testScript = ''
              import html
              import json
              import re
              import shlex
              from urllib.parse import urljoin

              machine.wait_for_unit("keycloak.service")
              machine.wait_for_open_port(${toString keycloakPort})
              machine.wait_for_unit("logseq-sync.service")
              machine.wait_for_open_port(${toString syncPort})
              machine.wait_for_unit("logseq-webapp.service")
              machine.wait_for_unit("nginx.service")

              # Record the realm's refresh events, so the refresh can be asserted
              # from the server side: a device-code poll and a refresh hit the
              # same token endpoint. Named explicitly because Keycloak doesn't
              # store REFRESH_TOKEN events by default, even with events on.
              # Admin tokens live a minute, so fetch one per call.
              def keycloak_admin(args):
                  token = machine.succeed(
                      "curl -sSf -d grant_type=password -d client_id=admin-cli"
                      " -d username=admin -d password=admin"
                      " http://localhost:${toString keycloakPort}/realms/master/protocol/openid-connect/token"
                      " | jq -er .access_token"
                  ).strip()
                  return machine.succeed(f"curl -sSf -H 'Authorization: Bearer {token}' {args}")

              keycloak_admin(
                  "-X PUT -H 'Content-Type: application/json' -d '{\"eventsEnabled\":true,\"enabledEventTypes\":[\"REFRESH_TOKEN\"]}'"
                  " http://localhost:${toString keycloakPort}/admin/realms/logseq/events/config"
              )

              # The user_info stub answers the preflight the desktop app sends...
              machine.succeed(
                  "curl -ksSf -X OPTIONS -H 'Origin: lsp://logseq.com' -D - -o /dev/null"
                  " https://app.test/file-sync/user_info | grep -qi '^access-control-allow-headers: authorization'"
              )
              # ...and the POST, with the group that gates sync.
              machine.succeed(
                  "curl -ksSf -X POST https://app.test/file-sync/user_info"
                  """ | jq -e '.UserGroups | index("rtc_2025_07_10")'"""
              )

              machine.succeed(
                  "systemd-run --unit=chromium -- ${lib.getExe pkgs.chromium} --headless --no-sandbox"
                  " --ignore-certificate-errors --enable-logging=stderr"
                  " --remote-debugging-port=9222 --remote-allow-origins=*"
                  " --user-data-dir=/tmp/chromium https://app.test/"
              )

              def js(expr):
                  return json.loads(machine.succeed(f"node ${cdp} {shlex.quote(expr)}"))

              def wait_for_js(expr, timeout=300):
                  machine.wait_until_succeeds(
                      f"node ${cdp} {shlex.quote(expr)} | grep -qx true", timeout=timeout
                  )

              try:
                  # The app boots and reaches the patched form. It routes by
                  # fragment, and its first start (creating the Demo graph) sends
                  # it home, so keep asking for #/login until that sticks.
                  wait_for_js(
                      "(location.hash === '#/login' || (location.hash = '#/login'),"
                      " document.getElementById('oidc-sign-in') !== null)"
                  )
                  # Starting the device flow gets a code from the realm, across
                  # origins, at the endpoint its discovery document names.
                  js("document.getElementById('oidc-sign-in').click()")
                  wait_for_js("document.getElementById('oidc-verification') !== null", timeout=60)
                  link = js("document.getElementById('oidc-verification').href")

                  # The user's half, on the IdP's own pages: open the link the app
                  # shows (verification_uri_complete, code included), then submit
                  # whatever Keycloak shows (login, then consent) until it stops
                  # showing forms. The app polls meanwhile.
                  def keycloak(args):
                      return machine.succeed(f"curl -sSL -b /tmp/kc -c /tmp/kc {args}")

                  assert "user_code=" in link, link
                  page = keycloak(f"'{link}'")
                  for _ in range(4):
                      form = re.search(r'<form[^>]*action="([^"]+)"', page)
                      if not form:
                          break
                      fields = {
                          m["name"]: html.unescape(m["value"])
                          for m in re.finditer(
                              r'<input(?=[^>]*name="(?P<name>[^"]+)")(?=[^>]*value="(?P<value>[^"]*)")',
                              page,
                          )
                      }
                      if 'name="username"' in page:
                          fields.update(username="test", password="test")
                      if 'name="accept"' in page:
                          fields["accept"] = "Yes"
                      action = urljoin(
                          "http://localhost:${toString keycloakPort}/", html.unescape(form[1])
                      )
                      data = " ".join(
                          f"--data-urlencode {shlex.quote(f'{k}={v}')}" for k, v in fields.items()
                      )
                      page = keycloak(f"{data} {shlex.quote(action)}")
                  assert "Device Login Successful" in page, page

                  # The app now holds the realm's tokens, including the refresh
                  # token logged-in? keys off...
                  wait_for_js("!!localStorage.getItem('refresh-token')", timeout=120)
                  # ...and uses them: user_info returned a map, so the logged-in
                  # flow went on to list the user's graphs, and the sync server
                  # accepted the token that request carried.
                  machine.wait_until_succeeds(
                      """grep -qE '"GET /graphs [^"]*" 200' /var/log/nginx/access.log""",
                      timeout=180,
                  )
                  # The ensure-token step before that request refreshed (Keycloak's
                  # 5-minute tokens are always within upstream's 1-hour "almost
                  # expired"), at the token endpoint discovery named.
                  refreshes = json.loads(
                      keycloak_admin(
                          "'http://localhost:${toString keycloakPort}/admin/realms/logseq/events"
                          "?type=REFRESH_TOKEN&client=logseq'"
                      )
                  )
                  assert refreshes, "the app never refreshed its token"
              except Exception:
                  print(machine.execute("journalctl -u chromium --no-pager | grep CONSOLE | tail -n 60")[1])
                  print(machine.execute("tail -n 50 /var/log/nginx/access.log")[1])
                  raise
            '';
          };

        # The sync *worker* — deps/db-sync's Cloudflare Worker build — against
        # the same realm. Same auth contract as `sync` (it's the same base
        # sync protocol underneath), plus proof the semantic REST/MCP layer
        # and the D1 migration step both actually work: entirely untested
        # before this check existed.
        sync-worker = pkgs.testers.runNixOSTest {
          name = "logseq-sync-worker";

          nodes.machine = {
            imports = [ stack ];
            # As behind a TLS proxy: MCP clients check the metadata against this.
            services.logseq-sync-worker.publicUrl = "https://sync.example.org";
          };

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
            # otherwise.
            token = machine.succeed(
                "curl -sSf -d grant_type=password -d client_id=logseq"
                " -d username=test -d password=test"
                " http://localhost:${toString keycloakPort}/realms/logseq/protocol/openid-connect/token"
                " | jq -er .access_token"
            ).strip()
            response = machine.succeed(
                f"curl -s -H 'Authorization: Bearer {token}' http://localhost:${toString syncWorkerPort}/graphs"
            )
            # A graphs list, not an error. This token has no cognito:username
            # (Keycloak puts that nowhere by default), and upstream's
            # <user-upsert!> bound the missing claim straight into D1, which
            # rejects `undefined` (D1_TYPE_ERROR). db-sync.patch falls back to
            # the standard preferred_username, as presence.cljs already did.
            assert '"graphs"' in response, f"a realm-minted token was refused: {response}"

            # MCP, as Claude Code and opencode connect to it. Without a token a
            # 401, upon which they read the protected-resource metadata under
            # /.well-known of the URL they connected to. Its resource has to be
            # that URL, so the public one, not the listen address.
            import base64
            import hashlib
            import html
            import json
            import re
            import shlex
            from urllib.parse import parse_qs, urlencode, urlparse

            worker = "http://localhost:${toString syncWorkerPort}"
            realm = "http://localhost:${toString keycloakPort}/realms/logseq"
            mcp = f"-H 'content-type: application/json' -H 'accept: application/json, text/event-stream' {worker}/mcp"
            headers = machine.succeed(f"curl -s -D - -o /dev/null -d '{{}}' {mcp}")
            assert headers.startswith("HTTP/1.1 401") and "WWW-Authenticate: Bearer" in headers, headers
            metadata = json.loads(machine.succeed(f"curl -sf {worker}/.well-known/oauth-protected-resource/mcp"))
            assert metadata["resource"] == "https://sync.example.org/mcp", metadata
            assert metadata["authorization_servers"] == [realm], metadata

            def claims(jwt):
                payload = jwt.split(".")[1]
                return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))

            # Both sign in with the realm's own public client, pre-registered
            # (--client-id / oauth.clientId), by authorization code + PKCE, on a
            # loopback redirect: Claude Code's on localhost, opencode's default.
            def sign_in(redirect_uri):
                verifier = "v" * 64
                challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
                query = urlencode({
                    "client_id": "logseq",
                    "response_type": "code",
                    "redirect_uri": redirect_uri,
                    "scope": " ".join(metadata["scopes_supported"]),
                    "code_challenge": challenge,
                    "code_challenge_method": "S256",
                    "state": "state",
                    "resource": metadata["resource"],
                })
                machine.succeed("rm -f /tmp/kc")
                page = machine.succeed(f"curl -sf -c /tmp/kc -b /tmp/kc '{realm}/protocol/openid-connect/auth?{query}'")
                form = re.search(r'action="([^"]+)"', page)
                assert form, page
                location = machine.succeed(
                    f"curl -s -c /tmp/kc -b /tmp/kc -o /dev/null -w '%{{redirect_url}}'"
                    f" -d username=test -d password=test {shlex.quote(html.unescape(form[1]))}"
                )
                assert location.startswith(redirect_uri + "?"), location
                code = parse_qs(urlparse(location).query)["code"][0]
                tokens = json.loads(machine.succeed(
                    f"curl -sf -d grant_type=authorization_code -d client_id=logseq -d code={code}"
                    f" -d code_verifier={verifier} --data-urlencode redirect_uri={shlex.quote(redirect_uri)}"
                    f" {realm}/protocol/openid-connect/token"
                ))
                return tokens["access_token"]

            for redirect_uri in ["http://localhost:47111/callback", "http://127.0.0.1:19876/mcp/oauth/callback"]:
                token = sign_in(redirect_uri)
                access = claims(token)
                assert access["aud"] == "logseq", access
                assert {"logseq/read", "logseq/write"} <= set(access["scope"].split()), access["scope"]
                auth = f"-H 'Authorization: Bearer {token}'"

                # The semantic REST API: past the scope check and the rate limiters.
                response = machine.succeed(f"curl -s -w ' %{{http_code}}' {auth} {worker}/api/v1/graphs")
                assert response.endswith(" 200") and '"graphs"' in response, response

                # And through MCP: a tool call runs code that calls that API.
                call = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
                    "name": "execute",
                    "arguments": {"code": 'async () => await codemode.request({ method: "GET", path: "/api/v1/graphs" })'},
                }})
                events = machine.succeed(f"curl -sf {auth} -d {shlex.quote(call)} {mcp}")
                data = [json.loads(line[6:]) for line in events.splitlines() if line.startswith("data: ")]
                assert data, events
                result = data[0]["result"]
                assert not result.get("isError") and "graphs" in result["content"][0]["text"], result
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

          nodes.machine = {
            imports = [ stack ];
            # A fixed user and a nested dataDir: StateDirectory creates it,
            # parents included, owned by that user.
            users.users.logseq = {
              isSystemUser = true;
              group = "logseq";
            };
            users.groups.logseq = { };
            services.logseq-publish = {
              user = "logseq";
              dataDir = "/var/lib/logseq/publish";
            };
          };

          testScript = ''
            machine.wait_for_unit("keycloak.service")
            machine.wait_for_open_port(${toString keycloakPort})
            machine.wait_for_unit("logseq-publish.service")
            machine.wait_for_open_port(${toString publishPort})
            machine.succeed("[ $(stat -c %U /var/lib/logseq/publish) = logseq ]")

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
            # Module scripts are refused as text/plain; this one is the PDF viewer.
            assert content_type("js/pdfjs/pdf.mjs") == "text/javascript"

            code = machine.succeed(
                "curl -so /dev/null -w %{http_code} http://localhost:8080/login"
            ).strip()
            assert code == "200", f"SPA fallback returned {code}"
          '';
        };

        # The container images. Only the web app's gets a check: it is the one
        # with logic of its own (an nginx config that has to serve
        # application/wasm for sqlite3.wasm, and a runner that turns LOGSEQ_*
        # variables into the client's config, from an unprivileged process). The sync and
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
                # The generic image, configured the way a consumer would.
                environment = {
                  LOGSEQ_OIDC_ISSUER = "https://id.example.org/realms/logseq";
                  LOGSEQ_OIDC_CLIENT_ID = "logseq";
                };
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

            # A stray real path still reaches the app (routes are fragments).
            code = machine.succeed(
                "curl -so /dev/null -w %{http_code} http://localhost:8080/login"
            ).strip()
            assert code == "200", f"SPA fallback returned {code}"

            # The environment reached the client's config, written by the runner
            # as the unprivileged container user, with no rebuild of the bundle.
            config = machine.succeed("curl -sSf http://localhost:8080/js/logseq-config.js")
            assert '"oidcIssuer":"https://id.example.org/realms/logseq"' in config, config
            assert '"cognitoClientId":"logseq"' in config, config
          '';
        };

        # No port to knock on, so check what a desktop install has to get right:
        # the launcher runs, the window manager can match the icon, and both halves
        # of the endpoint config landed: the app's baked js/logseq-config.js next
        # to upstream's fallbacks, and the OCaml CLI's substituted literals.
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
              grep -q '^StartupWMClass=Logseq$' "$app/share/applications/logseq.desktop"

              # The CLI half runs headless, so actually run it.
              node "$app/share/logseq/logseq-cli.js" --help | grep -q '^Usage: logseq'

              grep -q '${endpoints.apiDomain}' "$app/share/logseq/js/main.js"
              grep -q '^window.LOGSEQ_CONFIG = ' "$app/share/logseq/js/logseq-config.js"
              grep -q '${endpoints.syncUrl}' "$app/share/logseq/logseq-cli.js"

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
              unzip -p "$apk" assets/public/js/logseq-config.js | grep -q '^window.LOGSEQ_CONFIG = '

              touch $out
            '';
      };
    };
}
