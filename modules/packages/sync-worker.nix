# Logseq built from source: the self-hostable sync *worker* — deps/db-sync's
# Cloudflare Worker build, run against wrangler's local runtime, as opposed to
# sync.nix's plain-Node adapter.
#
# Same source tree, same package.json/pnpm-lock.yaml as sync.nix (shared via
# _common.nix's pnpmDepsSync/mldocSrc) — this compiles a different shadow-cljs
# build id (`db-sync`, not `db-sync-node`) and layers three things on top that
# the Node adapter doesn't have, all hand-written source files upstream ships
# beside the compiled output (deps/db-sync/worker/entry.mjs and siblings):
#
#   * A semantic REST API with generated OpenAPI docs (needs an extra build
#     step, `pnpm build:api-docs`, which shells out to the `redocly` CLI —
#     already a devDependency in the same package.json/lockfile, so no new
#     fetch).
#   * An MCP (Model Context Protocol) endpoint.
#   * ChatGPT "Apps" integration endpoints.
#
# Storage is D1 + Durable Object + R2, not the SQLite/filesystem sync.nix
# uses — genuinely incompatible with it, not two frontends onto one dataset
# (confirmed against the upstream-adjacent logseq-selfhost project's own
# README, which packages both the same way this file does).
#
# Structurally this is much closer to publish.nix (wrangler's local runtime,
# same CLOUDFLARE_INCLUDE_PROCESS_ENV=true/`[vars]`-stripping trick, same
# hand-written launcher because there's setup to do before exec) than to
# sync.nix — except this target's Worker also binds a D1 database, so unlike
# publish.nix's launcher, this one runs `wrangler d1 migrations apply` before
# `wrangler dev`.
let
  # A plain callPackage function, so the derivation stays usable from an
  # ordinary overlay.
  package =
    {
      lib,
      stdenv,
      callPackage,
      coreutils,
      runtimeShell,
      nodejs,
      wrangler,
      sqlite,
      zstd,
      python3,
      inputs,
    }:

    let
      common = callPackage ./_common.nix { inherit inputs; };
      inherit (common)
        version
        src
        pnpm
        setupSources
        fakeGit
        clojureWithDeps
        pnpmDepsSync
        mldocSrc
        ;
    in
    stdenv.mkDerivation (finalAttrs: {
      pname = "logseq-sync-worker";
      inherit version src;

      strictDeps = true;

      nativeBuildInputs = [
        nodejs
        pnpm
        clojureWithDeps
        fakeGit
        sqlite
        zstd
        python3
      ];

      # wrangler resolves `main` relative to the config file and puts its own
      # esbuild scratch dir (.wrangler/tmp) beside it — same reason
      # publish.nix's launcher exists rather than makeWrapper: the config
      # cannot stay in the read-only store, so this links the payload into
      # the data dir and runs from there. The D1 migrations step is this
      # target's one real difference from publish.nix's launcher — nothing
      # else here binds a D1 database.
      passAsFile = [ "launcher" ];
      launcher = ''
        #!${runtimeShell}
        set -eu
        export PATH=${lib.makeBinPath [ coreutils ]}

        : "''${SYNC_WORKER_DATA_DIR:=/var/lib/logseq-sync-worker}"
        : "''${SYNC_WORKER_IP:=0.0.0.0}"
        : "''${SYNC_WORKER_PORT:=8787}"

        share=${placeholder "out"}/share/${finalAttrs.pname}
        mkdir -p "$SYNC_WORKER_DATA_DIR/node_modules"
        # A symlink farm for worker/'s contents directly into the data dir,
        # not one symlink to the whole (read-only) worker/ directory: wrangler
        # resolves `main` (entry.mjs) relative to the config file and puts its
        # own esbuild scratch dir (.wrangler/tmp) beside it, so wrangler.toml
        # has to sit in a writable directory — one level down, under a
        # symlinked worker/, that mkdir lands in the store instead and fails.
        # entry.mjs's own sibling imports (chatgpt_app.mjs, mcp_request.mjs,
        # ..., dist/worker/main.js, dist/api-docs.generated.mjs) still resolve
        # correctly because they're relative to entry.mjs's real location,
        # which this farm preserves. Same node_modules/.mf writable-store
        # requirement as publish.nix; dotglob because pnpm's own symlinks
        # point into .pnpm/ and .bin/.
        #
        # No -n on this first `ln`, deliberately: under systemd's
        # DynamicUser+StateDirectory, $SYNC_WORKER_DATA_DIR itself
        # ("/var/lib/<name>") is a symlink to "private/<name>", and -n's
        # documented behavior ("treat LINK_NAME as a normal file if it is a
        # symbolic link to a directory") applies to the `-t` target argument
        # too — it made `ln` refuse to follow that symlink at all ("target
        # ...: Not a directory"), reproduced and confirmed by stat'ing
        # $SYNC_WORKER_DATA_DIR from inside a failing run. -f alone still
        # replaces each individual pre-existing entry on a re-run/restart;
        # -n was never doing anything useful for this call, only breaking it
        # under systemd specifically (a plain `nix run` or a container never
        # hits this, since there $SYNC_WORKER_DATA_DIR is a real directory).
        shopt -s dotglob
        ln -sft "$SYNC_WORKER_DATA_DIR" "$share"/worker/*
        ln -sfnt "$SYNC_WORKER_DATA_DIR/node_modules" "$share"/node_modules/*
        shopt -u dotglob
        cd "$SYNC_WORKER_DATA_DIR"

        export HOME="$SYNC_WORKER_DATA_DIR"
        export WRANGLER_SEND_METRICS=false
        # This is what puts COGNITO_*/D1/R2 config into the worker's `env`
        # binding — same mechanism as publish.nix; the worker reads nothing
        # else, so only its own variables are exported.
        export CLOUDFLARE_INCLUDE_PROCESS_ENV=true

        # wrangler only skips the "About to apply N migration(s)?" prompt
        # when it detects a non-interactive session; a real terminal's stdin
        # still triggers it even though nothing here can answer it. Redirect
        # stdin from /dev/null so it always sees non-interactive, matching
        # its own documented CI/CD behavior (apply proceeds, still backed up).
        ${lib.getExe wrangler} d1 migrations apply DB \
          --config wrangler.toml \
          --local \
          --persist-to "$SYNC_WORKER_DATA_DIR/state" \
          < /dev/null

        # The worker builds its MCP metadata URLs from request.url, which
        # behind a TLS proxy says http://127.0.0.1:<port>; MCP clients reject
        # metadata whose resource isn't the URL they connected to. wrangler
        # rewrites request.url to this origin instead.
        public=()
        url="''${SYNC_WORKER_PUBLIC_URL:-}"; url="''${url%/}"
        if [ -n "$url" ]; then
          public=(
            --local-upstream "''${url#*://}"
            --upstream-protocol "''${url%%://*}"
          )
        fi

        exec ${lib.getExe wrangler} dev \
          --config wrangler.toml \
          --ip "$SYNC_WORKER_IP" \
          --port "$SYNC_WORKER_PORT" \
          --persist-to "$SYNC_WORKER_DATA_DIR/state" \
          "''${public[@]}" \
          "$@"
      '';

      # Upstream fixes for non-Cognito providers: the user name from the
      # standard OIDC claim, and a 401 on /mcp that starts MCP clients' OAuth.
      patches = [ ./db-sync.patch ];

      preConfigure = setupSources {
        packageJsons = [
          "package.json"
          "deps/db-sync/package.json"
        ];
      };

      buildPhase = ''
        runHook preBuild

        # better-sqlite3 builds a native addon via node-gyp; without this it
        # tries to download Node headers matching the running Node's version
        # from nodejs.org. nixpkgs' nodejs ships those headers itself.
        export npm_config_nodedir=${nodejs}
        install_pnpm_store ${pnpmDepsSync} deps/db-sync --ignore-workspace

        mkdir -p deps/db-sync/node_modules/.pnpm/mldoc@1.5.9/node_modules
        cp -r ${mldocSrc} deps/db-sync/node_modules/.pnpm/mldoc@1.5.9/node_modules/mldoc
        chmod -R u+w deps/db-sync/node_modules/.pnpm/mldoc@1.5.9/node_modules/mldoc
        ln -sfn .pnpm/mldoc@1.5.9/node_modules/mldoc deps/db-sync/node_modules/mldoc

        (cd deps/db-sync && clojure -M:cljs release db-sync)
        # Encapsulates: db-sync-api-docs release, node worker/dist/api-docs-spec.js
        # (renders the openapi.json spec), redocly build-docs (static HTML docs),
        # and embed_api_docs.mjs (bakes both into dist/api-docs.generated.mjs,
        # which entry.mjs imports). COGNITO_ISSUER is exported inside the script
        # itself — needed only to stamp the generated docs, not a runtime value.
        (cd deps/db-sync && pnpm run build:api-docs)

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        # Same reasoning as publish.nix: [vars] (upstream's Cognito pool) and
        # the [env.*] staging/prod sections are deploy specific; config
        # arrives through the environment instead. Unlike publish.nix, what
        # sits between them stays: the semantic API (and so MCP) answers 503
        # without its [[ratelimits]] bindings. The greps fail the build
        # loudly rather than silently ship upstream's pool if the layout moves.
        toml=deps/db-sync/worker/wrangler.toml
        sed -i -e '/^\[vars\]/,/^$/d' -e '/^\[env\./,$d' $toml
        if grep 'COGNITO\|^\[env\.' $toml; then exit 1; fi
        grep -q '^\[\[ratelimits\]\]' $toml

        mkdir -p $out/share/${finalAttrs.pname}
        cp -r deps/db-sync/worker $out/share/${finalAttrs.pname}/worker
        cp -r deps/db-sync/node_modules $out/share/${finalAttrs.pname}/node_modules

        install -Dm755 "$launcherPath" $out/bin/${finalAttrs.pname}

        runHook postInstall
      '';

      meta = {
        description = "Self-hostable sync worker for Logseq (deps/db-sync Cloudflare Worker build: semantic REST, MCP, and ChatGPT Apps on top of the base sync protocol)";
        homepage = "https://github.com/logseq/logseq";
        license = lib.licenses.agpl3Only;
        platforms = lib.platforms.linux;
        mainProgram = finalAttrs.pname;
      };
    });
in
{ inputs, ... }:
{
  perSystem = { pkgs, ... }: {
    packages.logseq-sync-worker = pkgs.callPackage package { inherit inputs; };
  };
}
