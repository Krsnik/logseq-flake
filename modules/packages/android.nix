# Logseq built from source: the Android app.
#
# Was an impure single-FOD stepping stone (the whole Gradle build wrapped as
# one fixed-output derivation, because Gradle has no lockfile to build a
# fetch-then-offline-build split against, unlike deps.edn's :mvn/version
# pins or pnpm-lock.yaml). Now uses nixpkgs' own solution to exactly this
# problem — `gradle.fetchDeps`/`mitm-cache` — instead of reinventing one:
# `mitmCache` below is a small FOD that MITM-records Maven HTTP traffic into
# a URL->hash lockfile (android-deps.json), and the real build (an ordinary,
# non-FOD derivation) replays it through a local proxy. Only immutable
# artifact bytes get hashed, not Gradle's own timestamped cache-bookkeeping
# files (journal-1, modules-2.lock, ...), which is what made a naive "tar up
# ~/.gradle/caches" capture a real determinism risk instead of just an
# implementation detail. `clientConfig` overrides are free now (no `hash`
# argument, no fakeHash dance): `applyClientConfig` only patches web
# sources (.cljs literals, the ui package's login form), never
# build.gradle/AGP config, so the dependency set
# (and thus android-deps.json's content and mitmCache's hash) is completely
# independent of clientConfig — and the outer derivation is ordinary, so Nix
# content-addresses its own output from the full input closure automatically.
#
# Non-obvious mechanics, worth knowing before touching this file:
#
#   - gradle.fetchDeps's update script (regenerates android-deps.json) only
#     runs unpackPhase -> patchPhase -> configurePhase -> gradleUpdateScript
#     — it never reaches a custom buildPhase. That's why the whole pnpm/
#     gulp/cljs/webpack/`cap sync` pipeline lives in `preConfigure` here,
#     unlike every sibling target (which keep preConfigure to setup and put
#     the real build in buildPhase): preConfigure is the one hook point that
#     fires on both the capture path and the real build path. Confirmed by
#     reading nixpkgs' pkgs/development/tools/build-managers/gradle/
#     update-deps.nix directly, not assumed.
#   - preConfigure ends with `cd android`, and that cwd persists into
#     buildPhase (genericBuild runs every phase in one shell) — both the
#     auto-injected `gradleUpdateScript` (capture path, which calls `gradle
#     <task>` from wherever configurePhase left the shell) and our own
#     buildPhase's `gradle assembleRelease` need to run from android/, not
#     the repo root, since that's where the actual Gradle project lives.
#   - Uses nixpkgs' own Gradle (pkgs.gradle, currently 8.14.4 — a patch bump
#     over the project's pinned wrapper, 8.14.3), not android/gradlew: the
#     mitm-cache/gradle.fetchDeps plumbing is built entirely around the
#     `gradle` shell function nixpkgs' own setup hook installs, not an
#     arbitrary `./gradlew`-downloaded distribution.
#   - `-Pandroid.aapt2FromMavenOverride=...` is passed via `gradleFlags`, so
#     it's present during both the android-deps.json capture and the real
#     build — AGP should then never actually reach for the Maven-hosted
#     aapt2 at all during capture either, which is why that URL doesn't need
#     separate handling here.
#
# To regenerate android-deps.json after a Gradle-level dependency change (a
# new AAR/Maven coordinate, an AGP/Kotlin bump), from the flake root (cwd
# matters — the update script writes relative to it):
#   nix build path:.#logseq-android.mitmCache.updateScript --no-link --print-out-paths
#   <run the printed path>
let
  # A plain callPackage function, so `.override { clientConfig = ...; }`
  # keeps working and the derivation stays usable from an overlay.
  package =
    {
      lib,
      stdenvNoCC,
      pkgs,
      callPackage,
      jdk21,
      cacert,
      nodejs,
      pnpmConfigHook,
      gradle,
      autoPatchelfHook,
      zlib,
      ncurses5,
      stdenv,
      inputs,

      # Identity provider and sync/publish endpoints; keys in
      # _client-config.nix. Any subset may be overridden — free, unlike the old
      # single-FOD build: see the file header on why.
      clientConfig ? { },
    }:

    let
      common = callPackage ./_common.nix { inherit inputs; };

      # androidenv's SDK components are marked unfree and gate on an explicit
      # license acceptance; the ambient pkgs used elsewhere in this flake
      # doesn't set either, so re-import nixpkgs locally just for this rather
      # than threading allowUnfree through the whole flake's config.
      androidenv =
        (import pkgs.path {
          system = pkgs.stdenv.hostPlatform.system;
          config.allowUnfree = true;
          config.android_sdk.accept_license = true;
        }).androidenv;
      inherit (common)
        version
        src
        pnpm
        setupSources
        fakeGit
        clojureWithDeps
        pnpmDepsRoot
        pnpmDepsUi
        applyClientConfig
        ;

      androidComposition = androidenv.composeAndroidPackages {
        platformVersions = [ "36" ];
        buildToolsVersions = [
          "34.0.0" # apksigner — matches upstream CI, independent of compileSdk
          "35.0.0" # some AAR subprojects (e.g. capacitor-secure-storage) pin this
          "36.0.0"
        ];
        includeNDK = false;
        includeEmulator = false;
        includeSystemImages = false;
      };

      # Gradle execs aapt2 (a prebuilt ELF binary bundled in build-tools) as a
      # long-lived "daemon" subprocess by its raw path, not through PATH or a
      # nix wrapper — so its unpatched interpreter/rpath makes it fail to start
      # at all ("Daemon startup failed") under the Nix sandbox. Copy the SDK to
      # a writable derivation and autoPatchelf every native binary in it once,
      # rather than patching aapt2 alone (dx/zipalign/etc. hit the same issue).
      # stdenvNoCC: this only copies + autoPatchelfs, nothing compiles.
      androidSdkPatched = stdenvNoCC.mkDerivation {
        pname = "androidsdk-patched";
        version = androidComposition.androidsdk.version or "0";
        dontUnpack = true;
        nativeBuildInputs = [ autoPatchelfHook ];
        buildInputs = [
          stdenv.cc.cc.lib
          zlib
          ncurses5
        ];
        # renderscript's *.so under build-tools/*/renderscript/lib/packaged/ are
        # Android-target (bionic libc) libraries bundled *into the app*, not host
        # executables — they want liblog.so/libjnigraphics.so, which only exist
        # on-device. Nothing here runs them on the host, so a missing RPATH for
        # them is harmless; only the actual host tools (aapt2, aidl, ...) matter.
        autoPatchelfIgnoreMissingDeps = [
          "liblog.so"
          "libjnigraphics.so"
        ];
        installPhase = ''
          runHook preInstall
          cp -rL ${androidComposition.androidsdk} $out
          chmod -R u+w $out
          runHook postInstall
        '';
      };

      aapt2 = "${androidSdkPatched}/libexec/android-sdk/build-tools/36.0.0/aapt2";
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      pname = "logseq-android";
      inherit version src;

      strictDeps = true;

      nativeBuildInputs = [
        nodejs
        pnpm
        pnpmConfigHook
        clojureWithDeps
        fakeGit
        androidSdkPatched
        jdk21
        cacert
        gradle
      ];

      pnpmDeps = pnpmDepsRoot;

      # gradleUpdateTask must match the real build task (gradleBuildTask,
      # below, via buildPhase) so the captured lockfile covers everything
      # the real build resolves, not just configuration-time deps.
      gradleUpdateTask = "assembleRelease";
      gradleFlags = [
        "-Pandroid.aapt2FromMavenOverride=${aapt2}"
        # Release lint fetches maven.google.com's master-/group-index.xml (live
        # version listings for its "newer version available" check); pinning
        # those in android-deps.json breaks on every upstream release.
        "-x"
        "lintVitalRelease"
      ];

      mitmCache = gradle.fetchDeps {
        pname = finalAttrs.pname;
        pkg = finalAttrs.finalPackage;
        data = ./android-deps.json;
        silent = false;
        useBwrap = false;
      };

      env = {
        CI = "1";
        LOGSEQ_REVISION = version;
        LOGSEQ_SENTRY_DSN = "";
        LOGSEQ_POSTHOG_TOKEN = "";
        JAVA_HOME = jdk21;
        ANDROID_HOME = "${androidSdkPatched}/libexec/android-sdk";
        ANDROID_SDK_ROOT = "${androidSdkPatched}/libexec/android-sdk";
      };

      # Everything up through `cap sync android` has to be here, not in
      # preBuild/buildPhase — see the file header on why. Ends with `cd
      # android` so both the capture path's auto-invoked `gradle
      # <gradleUpdateTask>` and our own buildPhase run from the actual
      # Gradle project directory.
      # pnpmConfigHook normally runs as a postConfigure hook (after this whole
      # preConfigure, before buildPhase) — too late here, since everything
      # else needs to be in preConfigure too (see the file header). Root's
      # node_modules has to exist before packages/ui's own install, though:
      # its postinstall (`parcel build --target ui`) resolves a hoisted
      # polyfill from the root install, and fails ("process/ ... auto
      # install is disabled") if that hasn't happened yet — reproduced by
      # getting the ordering wrong once, fixed by calling the hook function
      # manually in the right spot instead of letting it auto-run late.
      dontPnpmConfigure = true;
      preConfigure = ''
        ${setupSources {
          packageJsons = [
            "package.json"
            "packages/ui/package.json"
          ];
        }}

        pnpmConfigHook
        ${applyClientConfig clientConfig}

        install_pnpm_store ${pnpmDepsUi} packages/ui

        pnpm gulp:buildMobile
        pnpm cljs:release-mobile
        pnpm webpack-mobile-build

        # capacitor.config.ts reads static/package.json for the app version
        # string; nothing in the mobile pipeline creates it otherwise (only
        # desktop.nix's postBuild does, for the electron app).
        cp resources/package.json static/package.json

        pnpm exec cap sync android

        cd android
      '';

      buildPhase = ''
        runHook preBuild
        gradle assembleRelease
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        find app/build/outputs/apk -name '*.apk' -exec install -Dm644 {} -t $out \;
        runHook postInstall
      '';

      meta = {
        description = "Logseq for Android (unsigned APK)";
        homepage = "https://github.com/logseq/logseq";
        license = lib.licenses.agpl3Only;
        platforms = [ "x86_64-linux" ];
      };
    });
in
{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      system,
      lib,
      ...
    }:
    {
      # The Android SDK binaries this needs are x86_64-only. The condition
      # has to sit inside `packages`, not around the whole perSystem module:
      # a module whose very shape depends on `system` defeats flake-parts'
      # static analysis of which outputs exist, and `nix flake check` fails
      # on the `formatter` output it can then no longer rule out.
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        logseq-android = pkgs.callPackage package { inherit inputs; };
      };
    };
}
