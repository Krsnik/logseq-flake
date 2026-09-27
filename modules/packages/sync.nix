# Logseq built from source: the self-hostable sync server (deps/db-sync's
# plain-Node adapter, not the Cloudflare Worker build deployed upstream).
#
# Unlike the client targets, identity-provider/sync config here is already
# runtime env vars (COGNITO_ISSUER, COGNITO_CLIENT_ID, COGNITO_JWKS_URL, ...)
# read by deps/db-sync/src/logseq/db_sync/node/config.cljs — no source
# patching needed, so this target takes no clientConfig argument. Reuses
# _common.nix's src/clojureDeps/setupSources; deps/db-sync has its own
# package.json + pnpm-lock.yaml (own fetchPnpmDeps pass) but needs no
# separate Maven FOD — see the comment on clojureDeps in _common.nix for why.
let
  # A plain callPackage function, so `.override { clientConfig = ...; }`
  # keeps working and the derivation stays usable from an overlay.
  package =
    {
      lib,
      stdenv,
      callPackage,
      makeWrapper,
      nodejs,
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
      pname = "logseq-sync";
      inherit version src;

      strictDeps = true;

      nativeBuildInputs = [
        nodejs
        pnpm
        clojureWithDeps
        fakeGit
        makeWrapper
        sqlite
        zstd
        python3
      ];

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

        (cd deps/db-sync && clojure -M:cljs release db-sync-node)

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out/share/${finalAttrs.pname}
        cp -r deps/db-sync/worker/dist $out/share/${finalAttrs.pname}/dist
        cp -r deps/db-sync/node_modules $out/share/${finalAttrs.pname}/node_modules

        makeWrapper ${lib.getExe' nodejs "node"} $out/bin/${finalAttrs.pname} \
          --add-flags "$out/share/${finalAttrs.pname}/dist/node-adapter.js" \
          --set-default DB_SYNC_DATA_DIR /var/lib/logseq-sync \
          --set-default DB_SYNC_STORAGE_DRIVER sqlite \
          --set-default DB_SYNC_ASSETS_DRIVER filesystem

        runHook postInstall
      '';

      meta = {
        description = "Self-hostable sync server for Logseq (deps/db-sync Node adapter)";
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
    packages.logseq-sync = pkgs.callPackage package { inherit inputs; };
  };
}
