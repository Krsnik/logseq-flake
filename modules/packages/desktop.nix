# Logseq built from source: the Linux desktop client (electron).
let
  # A plain callPackage function, so `.override { clientConfig = ...; }` keeps working and the derivation stays usable from an overlay.
  package =
    {
      lib,
      stdenv,
      callPackage,
      fetchFromGitHub,
      fetchurl,
      ocaml-ng,
      makeWrapper,
      makeDesktopItem,
      copyDesktopItems,
      pnpmConfigHook,
      nodejs,
      git,
      electron_42,
      sqlite,
      python3,
      pkg-config,
      zstd,
      libsecret,
      inputs,

      # Identity provider and sync/publish endpoints; keys in
      # _client-config.nix. Any subset may be overridden.
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
        mkPnpmDeps
        pnpmStoreHelper
        applyClientConfig
        applyCliConfig
        defaultClientConfig
        ;

      # The bundled OCaml CLI still substitutes literals, so it needs every key.
      cfg = defaultClientConfig // clientConfig;
      electron = electron_42;

      # Static (electron app) pnpm deps — resources/ is the standalone electron
      # app, not a root workspace member.
      pnpmDepsStatic = mkPnpmDeps {
        pname = "logseq-static";
        subdir = "resources";
        hash = "sha256-V3oZwNPO2eBbKgBB9T/T65qLSrJ0Z9vrqGM9YpQXxqw=";
      };

      # --- OCaml toolchain for the CLI -----------------------------------------
      #
      # `ocamlPackages` (unqualified) is a floating alias to whatever nixpkgs
      # calls "latest" — nixos-unstable's 2026-09 update moved that from OCaml
      # 5.4.1 to 5.5.0, and 5.5's stricter exhaustiveness checker turns upstream's
      # cli/lib/cli.ml (an unmodified vendored file) non-exhaustive-match warning
      # into a hard error under dune's default profile. Pinning the numbered
      # scope keeps the compiler version stable across nixpkgs bumps without
      # pinning nixpkgs itself.
      #
      # cli/dune-project declares (lang dune 3.23), and humanize and rrbvec both
      # require dune >= 3.23, while nixpkgs ships 3.21.1. Override the version
      # inside the same scope rather than beside it, so melange and every
      # library below are compiled against the same dune as the CLI itself.
      ocamlPkgs = ocaml-ng.ocamlPackages_5_4.overrideScope (
        _final: prev: {
          dune_3 = prev.dune_3.overrideAttrs (_: rec {
            version = "3.23.0";
            src = fetchurl {
              url = "https://github.com/ocaml/dune/releases/download/${version}/dune-${version}.tbz";
              hash = "sha256-6SmH/+S8eVaxiyJRsPmETVXfo4cDXOYKPw/VrE4mF9Q=";
            };
          });
        }
      );

      # The CLI's dependencies that nixpkgs does not carry. Upstream reaches these
      # through opam `pin-depends` on floating `#main` branches; here each one is
      # an ordinary fetchFromGitHub at a fixed revision, so the pins live in the
      # same place as every other source hash in this file. melange-edn and
      # melange-transit each publish several opam packages from one repository,
      # and buildDunePackage builds `-p ${pname}`, so they appear twice.
      # Shared shape for the seven libraries below. melc is a build-time binary and
      # buildDunePackage sets strictDeps, so melange has to be in nativeBuildInputs
      # and not only propagated — the same shape nixpkgs uses for melange-json.
      # Their test suites want alcotest/qcheck/bechamel, which @bundle does not.
      mkOcamlLib =
        args:
        ocamlPkgs.buildDunePackage (
          {
            nativeBuildInputs = [ ocamlPkgs.melange ];
            doCheck = false;
          }
          // args
        );

      melange-edn-src = fetchFromGitHub {
        owner = "RCmerci";
        repo = "melange-edn";
        rev = "3cb79f278e972388a0a2b2ea1caec7a008a0b956";
        hash = "sha256-mdkjo4csQrQw0uTYaQ2gjlGp2kHSjN3PL4ljFDDTwQ8=";
      };
      melange-transit-src = fetchFromGitHub {
        owner = "RCmerci";
        repo = "melange-transit";
        rev = "950a5786e343f893a6e0396819383db341d5aa97";
        hash = "sha256-n+K7XtNNjVJ5+gvt4y2yP9f5iyYldM60dT/qXyhp4Pg=";
      };

      melange-edn-core = mkOcamlLib {
        pname = "melange-edn-core";
        version = "0.5.0";
        src = melange-edn-src;
      };
      melange-edn-melange = mkOcamlLib {
        pname = "melange-edn-melange";
        version = "0.5.0";
        src = melange-edn-src;
        propagatedBuildInputs = [
          ocamlPkgs.melange
          melange-edn-core
        ];
      };
      melange-transit-core = mkOcamlLib {
        pname = "melange-transit-core";
        version = "0.1.0";
        src = melange-transit-src;
      };
      melange-transit-melange = mkOcamlLib {
        pname = "melange-transit-melange";
        version = "0.1.0";
        src = melange-transit-src;
        propagatedBuildInputs = [
          ocamlPkgs.melange
          melange-transit-core
          melange-edn-melange
        ];
      };
      humanize = mkOcamlLib {
        pname = "humanize";
        version = "0-unstable-2025-06-05";
        src = fetchFromGitHub {
          owner = "rcmerci";
          repo = "humanize";
          rev = "747879af704dff4dd1897bc0f9a53a361071371c";
          hash = "sha256-NalrZxGlcMAIAjX6x7fFLJFZKEcr8E3R83iM87TfyyE=";
        };
        propagatedBuildInputs = [ ocamlPkgs.melange ];
      };
      rrbvec = mkOcamlLib {
        pname = "rrbvec";
        version = "0-unstable-2026-06-11";
        src = fetchFromGitHub {
          owner = "RCmerci";
          repo = "rrbvec";
          rev = "dd5ce904f91d53235b5136f7a771f3f074c3971d";
          hash = "sha256-zYT7cMMWJivVSB6H/vUDnaajvUOYddh0MF2Zu/wIGq0=";
        };
        propagatedBuildInputs = [
          ocamlPkgs.melange
          ocamlPkgs.js_of_ocaml
        ];
      };
      melange-fetch = mkOcamlLib {
        pname = "melange-fetch";
        version = "0-unstable-2026-06-28";
        src = fetchFromGitHub {
          owner = "melange-community";
          repo = "melange-fetch";
          rev = "0ec5e4b11cfd76171ac98661097f0bbd753e2973";
          hash = "sha256-Wls6sxDaA3hFetBN6+kVC2lp7Hpg9OGeev02eHBAIe4=";
        };
        propagatedBuildInputs = [ ocamlPkgs.melange ];
      };

      # vite does the final bundling, driven by the @bundle rule in cli/dist/dune,
      # so the CLI needs its own node_modules alongside the OCaml libraries.
      pnpmDepsCli = mkPnpmDeps {
        pname = "logseq-cli";
        subdir = "cli";
        hash = "sha256-fZBXOtG6b/oa9JNvj8/gY72xDzGG26O7LQmwvsWeEbs=";
      };

      cliBundle = stdenv.mkDerivation (finalAttrs: {
        pname = "logseq-cli";
        inherit version src;

        nativeBuildInputs = [
          ocamlPkgs.dune_3
          ocamlPkgs.ocaml
          ocamlPkgs.findlib
          ocamlPkgs.melange
          nodejs
          pnpm
          zstd
          sqlite
        ];

        buildInputs = [
          melange-edn-melange
          melange-transit-melange
          melange-fetch
          humanize
          rrbvec
        ];

        # vite.config.mjs stamps the bundle with `new Date().toISOString()` unless
        # these are set; pinning them keeps successive builds identical.
        env = {
          LOGSEQ_BUILD_TIME = "1970-01-01T00:00:00.000Z";
          LOGSEQ_REVISION = version;
        };

        postPatch = ''
          sed -i '/packageManager/d' package.json
          ${applyCliConfig cfg}
          # cli/test is the only consumer of melange-fest, which nixpkgs does not
          # carry and @bundle does not need; drop it so dune never resolves it.
          rm -rf cli/test
        '';

        buildPhase = ''
          runHook preBuild
          export HOME=$(mktemp -d)
          ${pnpmStoreHelper}
          install_pnpm_store ${pnpmDepsCli} cli --ignore-workspace
          cd cli && dune build @bundle
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          install -Dm644 _build/default/dist/logseq-cli.js $out/${finalAttrs.pname}.js
          runHook postInstall
        '';
      });
    in
    stdenv.mkDerivation (finalAttrs: {
      pname = "logseq";
      inherit version src;

      strictDeps = true;

      nativeBuildInputs = [
        nodejs
        pnpm
        pnpmConfigHook
        clojureWithDeps
        fakeGit
        makeWrapper
        copyDesktopItems
        sqlite
        python3
        pkg-config
      ];

      buildInputs = [ libsecret ];

      pnpmDeps = pnpmDepsRoot;

      env = {
        ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
        CI = "1";
        LOGSEQ_REVISION = version;
        LOGSEQ_SENTRY_DSN = "";
        LOGSEQ_POSTHOG_TOKEN = "";
      };

      # Upstream fix: plugin installs unzipped the download before it was
      # fully written, and failed with a truncated zip.
      patches = [ ./desktop.patch ];

      preConfigure = ''
        ${setupSources {
          packageJsons = [
            "package.json"
            "packages/ui/package.json"
            "resources/package.json"
          ];
        }}
        ${applyClientConfig clientConfig}
      '';

      preBuild = ''
        install_pnpm_store ${pnpmDepsUi} packages/ui
      '';

      buildPhase = ''
        runHook preBuild

        pnpm gulp:build
        pnpm cljs:release-electron
        pnpm db-worker-node:bundle

        cp ${cliBundle}/${cliBundle.pname}.js static/${cliBundle.pname}.js

        pnpm webpack-app-build
        pnpm desktop:prepare-runtime-js

        runHook postBuild
      '';

      postBuild = ''
        cp resources/package.json static/package.json
        cp resources/pnpm-lock.yaml static/pnpm-lock.yaml

        # --ignore-workspace: static/ is the standalone electron app, not a pnpm
        # workspace member. Without it pnpm hoists the deps up to the root.
        install_pnpm_store ${pnpmDepsStatic} static --ignore-scripts --ignore-workspace

        # keytar builds a native .node via node-gyp.
        export npm_config_nodedir=${electron.headers}
        (cd static && pnpm rebuild keytar --ignore-workspace)
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out/share/${finalAttrs.pname}
        cp -r static/. $out/share/${finalAttrs.pname}/

        # Prune mobile/android/ios — desktop build doesn't need them
        # (mirrors upstream's pruneDesktopPackageFiles in gulpfile.js).
        rm -rf $out/share/${finalAttrs.pname}/{mobile,android,ios,dist}

        # node-gyp leaves Makefiles, *.mk, config.gypi and .deps beside the built
        # addon, all referencing build-time-only store paths; only keytar.node is
        # needed at runtime. node_modules/keytar symlinks into .pnpm, so fixing
        # the one real copy suffices. Globbed on version, and deliberately without
        # a `|| true`: a layout change should fail the build, not silently ship a
        # Logseq whose keychain access is gone.
        keytarBuild=$(echo $out/share/${finalAttrs.pname}/node_modules/.pnpm/keytar@*/node_modules/keytar/build)
        mv "$keytarBuild/Release/keytar.node" "$TMPDIR/keytar.node"
        rm -rf "$keytarBuild"
        install -Dm755 "$TMPDIR/keytar.node" "$keytarBuild/Release/keytar.node"

        install -Dm644 static/icons/logseq.png \
          "$out/share/icons/hicolor/512x512/apps/logseq.png"

        # --class: --inherit-argv0 makes Electron's argv0 (and thus its default
        # WM_CLASS) "logseq" (the wrapper's lowercase basename), but the .desktop
        # file below declares StartupWMClass "Logseq" (capitalized, matching
        # upstream's productName). That mismatch is why the icon shows in the
        # app picker (reads the .desktop file directly) but not in the taskbar
        # (groups windows by live WM_CLASS). Forcing --class here makes them match.
        # Both --enable-features uses are merged into one flag: Chromium only
        # keeps the last --enable-features switch it sees, so a separate
        # Wayland-only --enable-features would silently clobber the VAAPI one.
        makeWrapper ${lib.getExe electron} $out/bin/${finalAttrs.pname} \
          --add-flags $out/share/${finalAttrs.pname} \
          --add-flags "--class=Logseq --enable-features=VaapiVideoDecoder,VaapiVideoEncoder\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+,WaylandWindowDecorations}}" \
          --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-wayland-ime=true --wayland-text-input-version=3}}" \
          --set-default LOCAL_GIT_DIRECTORY ${git} \
          --inherit-argv0

        runHook postInstall
      '';

      desktopItems = [
        (makeDesktopItem {
          # logseq.desktop, lowercase: on Wayland the window's app_id is
          # "logseq" (--class only sets the X11 WM_CLASS), and GNOME matches a
          # window to <app_id>.desktop by name, case-sensitively. As
          # Logseq.desktop the window had no app, so no icon and no entry in
          # the dash. StartupWMClass below still covers X11.
          name = finalAttrs.pname;
          desktopName = "Logseq";
          exec = "${finalAttrs.pname} %U";
          terminal = false;
          icon = "logseq";
          startupWMClass = "Logseq";
          comment = "A privacy-first, open-source platform for knowledge management and collaboration.";
          mimeTypes = [ "x-scheme-handler/logseq" ];
          categories = [ "Utility" ];
        })
      ];

      meta = {
        description = "Privacy-first, open-source platform for knowledge management and collaboration";
        homepage = "https://github.com/logseq/logseq";
        license = lib.licenses.agpl3Only;
        platforms = electron.meta.platforms;
        mainProgram = finalAttrs.pname;
      };
    });
in
{ inputs, ... }:
{
  perSystem = { pkgs, ... }: {
    packages.logseq = pkgs.callPackage package { inherit inputs; };
  };
}
