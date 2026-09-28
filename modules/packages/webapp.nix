# Logseq built from source: the web app (static PWA bundle, no Electron).
let
  # A plain callPackage function, so `.override { clientConfig = ...; }`
  # keeps working and the derivation stays usable from an overlay.
  package =
    {
      lib,
      callPackage,
      stdenvNoCC,
      nodejs,
      pnpmConfigHook,
      inputs,

      # Identity provider and sync/publish endpoints, baked in as defaults the
      # server may still override at runtime; keys in _client-config.nix.
      clientConfig ? { },
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
        pnpmDepsRoot
        pnpmDepsUi
        ;
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      pname = "logseq-webapp";
      inherit version src;

      strictDeps = true;

      nativeBuildInputs = [
        nodejs
        pnpm
        pnpmConfigHook
        clojureWithDeps
        fakeGit
      ];

      pnpmDeps = pnpmDepsRoot;

      env = {
        CI = "1";
        LOGSEQ_REVISION = version;
        LOGSEQ_SENTRY_DSN = "";
        LOGSEQ_POSTHOG_TOKEN = "";
      };

      preConfigure = ''
        ${setupSources {
          packageJsons = [
            "package.json"
            "packages/ui/package.json"
          ];
        }}
        ${common.applyClientConfig clientConfig}
      '';

      preBuild = ''
        install_pnpm_store ${pnpmDepsUi} packages/ui
      '';

      buildPhase = ''
        runHook preBuild
        pnpm release-app
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out/share/${finalAttrs.pname}
        cp -r static/. $out/share/${finalAttrs.pname}/

        # gulp's syncResourceFile copies the whole resources/ tree regardless of
        # build target, and cljs:release-app compiles db-worker-node alongside
        # the browser db-worker even though webpack-app-build never bundles it
        # (mirrors upstream's own pruneDesktopPackageFiles in gulpfile.js, for a
        # web target instead of a desktop one). None of this belongs in a static
        # web app: desktop packaging metadata, macOS entitlements, the
        # Capacitor mobile bundle, and the Node-only db-worker.
        rm -rf $out/share/${finalAttrs.pname}/{mobile,windows,docs,electron-builder.yml,forge.config.test.js,entitlements.plist,icons.edn,package.json,pnpm-lock.yaml,db-worker-node.js,db-worker-node.js.map}

        runHook postInstall
      '';

      # What _webapp-nginx.nix's runner layers the environment over.
      passthru = { inherit clientConfig; };

      meta = {
        description = "Privacy-first, open-source platform for knowledge management and collaboration (static web app)";
        homepage = "https://github.com/logseq/logseq";
        license = lib.licenses.agpl3Only;
      };
    });
in
{ inputs, ... }:
{
  perSystem = { pkgs, ... }: {
    packages.logseq-webapp = pkgs.callPackage package { inherit inputs; };
  };
}
