# Logseq built from source: the self-hostable publish service (deps/publish's Cloudflare Worker,
# run against wrangler's local workerd runtime instead of Cloudflare).
let
  # A plain callPackage function, so the derivation stays usable from an
  # ordinary overlay.
  package =
    {
      lib,
      stdenvNoCC,
      callPackage,
      coreutils,
      runtimeShell,
      nodejs,
      wrangler,
      sqlite,
      zstd,
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
        mkPnpmDeps
        ;

      pnpmDepsPublish = mkPnpmDeps {
        pname = "logseq-publish";
        subdir = "deps/publish";
        hash = "sha256-TFIKbiDzNxjB1VM6DiQKFd1++gF82xUxMPpH/K0PZW0=";
      };
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      pname = "logseq-publish";
      inherit version src;

      strictDeps = true;

      nativeBuildInputs = [
        nodejs
        pnpm
        clojureWithDeps
        fakeGit
        sqlite
        zstd
      ];

      # wrangler resolves `main` relative to the config file and puts its own
      # esbuild scratch directory (.wrangler/tmp) beside it, so the config
      # cannot stay in the read-only store: link the payload into the data dir
      # and run from there. Written by Nix rather than makeWrapper because the
      # launcher has real work to do before exec.
      passAsFile = [ "launcher" ];
      launcher = ''
        #!${runtimeShell}
        set -eu
        export PATH=${lib.makeBinPath [ coreutils ]}

        : "''${PUBLISH_DATA_DIR:=/var/lib/logseq-publish}"
        : "''${PUBLISH_IP:=0.0.0.0}"
        : "''${PUBLISH_PORT:=8787}"

        share=${placeholder "out"}/share/${finalAttrs.pname}
        mkdir -p "$PUBLISH_DATA_DIR/node_modules"
        ln -sfn "$share/dist" "$PUBLISH_DATA_DIR/dist"
        install -m644 "$share/wrangler.toml" "$PUBLISH_DATA_DIR/wrangler.toml"
        # A symlink farm rather than one symlink to the store directory:
        # miniflare caches its Request.cf placeholder in node_modules/.mf, so
        # node_modules itself has to be writable. dotglob because pnpm's own
        # symlinks point into .pnpm/ and .bin/.
        shopt -s dotglob
        ln -sfnt "$PUBLISH_DATA_DIR/node_modules" "$share"/node_modules/*
        shopt -u dotglob
        cd "$PUBLISH_DATA_DIR"

        export HOME="$PUBLISH_DATA_DIR"
        export WRANGLER_SEND_METRICS=false
        # This is what puts COGNITO_*/R2_* into the worker's `env` binding. It
        # exports the *whole* process environment, so give the service only the
        # variables it needs (the worker reads nothing else).
        export CLOUDFLARE_INCLUDE_PROCESS_ENV=true

        # Without internet, wrangler logs one `getaddrinfo ENOTFOUND
        # workers.cloudflare.com` at startup. That is it failing to fetch the
        # Request.cf placeholder, which it then substitutes a default for; the
        # worker serves fine. Not a real failure, and not worth a network hole.
        exec ${lib.getExe wrangler} dev \
          --config wrangler.toml \
          --ip "$PUBLISH_IP" \
          --port "$PUBLISH_PORT" \
          --persist-to state \
          "$@"
      '';

      preConfigure = setupSources {
        packageJsons = [
          "package.json"
          "deps/publish/package.json"
        ];
      };

      buildPhase = ''
        runHook preBuild

        install_pnpm_store ${pnpmDepsPublish} deps/publish --ignore-workspace

        (cd deps/publish && clojure -M:cljs release publish-worker)

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        # Everything from [vars] on in upstream's wrangler.toml is deploy
        # specific: its own Cognito pool, the staging/prod environments and the
        # logseq.io custom domain. The bindings and the DO migration above it
        # are what the worker actually needs, so keep those and drop the rest;
        # config arrives through the environment instead (see the header). The
        # grep is there to fail the build rather than silently ship upstream's
        # pool if that block ever moves.
        grep -q '^\[vars\]' deps/publish/worker/wrangler.toml
        sed -i '/^\[vars\]/,$d' deps/publish/worker/wrangler.toml

        mkdir -p $out/share/${finalAttrs.pname}
        cp deps/publish/worker/wrangler.toml $out/share/${finalAttrs.pname}/
        cp -r deps/publish/worker/dist $out/share/${finalAttrs.pname}/dist
        cp -r deps/publish/node_modules $out/share/${finalAttrs.pname}/node_modules

        install -Dm755 "$launcherPath" $out/bin/${finalAttrs.pname}

        runHook postInstall
      '';

      meta = {
        description = "Self-hostable publish service for Logseq (deps/publish worker on wrangler's local runtime)";
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
    packages.logseq-publish = pkgs.callPackage package { inherit inputs; };
  };
}
