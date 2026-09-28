# The nginx recipe for serving the static webapp bundle — shared by
# images.nix's container image and ../apps/webapp.nix's `nix run` wrapper.
# Not itself a flake-parts module (see the `_` prefix).
#
# Paths are relative (pid, temp dirs), resolved against whatever `-p <dir>`
# the caller launches nginx with, rather than hardcoded to /tmp: a container
# only ever has its own /tmp, but a `nix run` on a shared host needs a fresh
# writable directory per invocation instead, so the same conf file has to
# work under either.
{ nginx, writeText }:
{
  webapp,
  port ? 8080,
}:
writeText "logseq-webapp-nginx.conf" ''
  daemon off;
  # The bare keyword, not a /dev/stderr path: nginx's error_log recognizes
  # "stderr" specially and writes straight to the inherited fd, no open()
  # syscall on a path involved (same reason nixpkgs' own services.nginx
  # module defaults to this). /dev/stderr is a real, reopenable device under
  # a container or a plain shell, but under systemd stderr is a socket to
  # the journal, and reopening *that* via a /dev/stderr path fails with
  # ENXIO — reproduced running this conf as a systemd service, fixed by
  # switching to the keyword, which works identically in all three contexts
  # (container, `nix run`, systemd) since it never touches the filesystem.
  error_log stderr warn;
  pid nginx.pid;
  events { }
  http {
    # nginx ships mime.types covering wasm; the browser refuses to instantiate
    # js/sqlite3.wasm as anything else.
    include ${nginx}/conf/mime.types;
    # ...but not .mjs, which it would serve as text/plain; browsers refuse
    # that for a module script, and js/pdfjs/pdf.mjs is how the PDF viewer
    # loads.
    types {
      text/javascript mjs;
    }

    # Off, not /dev/stdout: unlike error_log, nginx's access_log module has
    # no "stdout" magic keyword — it always does a path-based open(), which
    # hits the same ENXIO-under-systemd problem error_log's fix (above)
    # sidesteps. Nothing here reads access logs, so off is simplest.
    access_log off;

    client_body_temp_path client_body;
    proxy_temp_path proxy;
    fastcgi_temp_path fastcgi;
    uwsgi_temp_path uwsgi;
    scgi_temp_path scgi;

    server {
      listen ${toString port};
      root ${webapp}/share/logseq-webapp;
      index index.html;
      # The app routes by fragment (#/login; frontend/core.cljs starts reitit
      # with :use-fragment), so it never needs this itself. It only turns a
      # stray real path like /login into the app rather than a 404.
      location / {
        try_files $uri $uri/ /index.html;
      }

      # The one piece of upstream's account API the logged-in flow cannot do
      # without. :user/fetch-info-and-graphs (frontend/handler/events/ui.cljs)
      # fetches no graphs and starts no sync unless
      # POST https://<clientConfig.apiDomain>/file-sync/user_info returns a
      # map, and all it reads is :UserGroups — rtc_2025_07_10 is the group
      # user-handler/rtc-group? gates sync on. Static and the same for
      # everyone, because it grants nothing: the sync server does its own
      # auth, the client only uses this to decide whether to try. So point
      # apiDomain at wherever this bundle is served.
      location = /file-sync/user_info {
        # The desktop and mobile apps call it cross-origin, with a bearer token.
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Headers "authorization, content-type" always;
        if ($request_method = OPTIONS) {
          return 204;
        }
        default_type application/json;
        return 200 '{"UserGroups":["rtc_2025_07_10"]}';
      }
    }
  }
''
