# Shared FODs and helpers for every Logseq target (desktop, web app, sync, server, ...).
{
  lib,
  stdenvNoCC,
  fetchPnpmDeps,
  fetchzip,
  clojure,
  writeShellScriptBin,
  writeText,
  git,
  cacert,
  pnpm_10,
  inputs,
}:

let
  version = "2.0.1";
  rev = version;

  pnpm = pnpm_10;

  clientConfigKeys = import ./_client-config.nix;

  # The pinned Logseq source, as a flake input (flake.nix) rather than a
  # fetchFromGitHub call here — see flake.nix's comment on why.
  src = inputs.logseq-src;

  # All git deps from the root deps.edn (superset of every subproject's deps),
  # each its own flake input. Symlinked into GITLIBS so tools.deps finds them
  # without cloning. `libpath` is the Clojure lib name from deps.edn; the sha
  # tools.gitlibs expects as the directory name comes straight off the
  # input's own `.rev`, not retyped here.
  gitLibs = [
    {
      input = inputs.hsx-src;
      libpath = "io.factorhouse/hsx";
    }
    {
      input = inputs.datascript-src;
      libpath = "datascript/datascript";
    }
    {
      input = inputs.cljs-time-src;
      libpath = "com.andrewmcveigh/cljs-time";
    }
    {
      input = inputs.glogi-src;
      libpath = "com.lambdaisland/glogi";
    }
    {
      input = inputs.logseq-schema-src;
      libpath = "logseq/logseq-schema";
    }
    {
      input = inputs.malli-src;
      libpath = "metosin/malli";
    }
    {
      input = inputs.cljc-fsrs-src;
      libpath = "io.github.open-spaced-repetition/cljc-fsrs";
    }
    {
      input = inputs.cljs-http-missionary-src;
      libpath = "io.github.rcmerci/cljs-http-missionary";
    }
    {
      input = inputs.clj-fractional-indexing-src;
      libpath = "logseq/clj-fractional-indexing";
    }
    {
      input = inputs.rfx-src;
      libpath = "io.github.logseq/rfx";
    }
  ];

  # Pre-populate GITLIBS with the flake-input sources so clj doesn't need network access.
  setupGitLibs = ''
    export GITLIBS=$(mktemp -d)
    mkdir -p "$GITLIBS/libs"
    link_gitlib() {
        local src="$1" libpath="$2" sha="$3"
        mkdir -p "$GITLIBS/libs/$libpath"
        ln -s "$src" "$GITLIBS/libs/$libpath/$sha"
    }
    ${lib.concatMapStringsSep "\n" (
      gitlib: "link_gitlib ${gitlib.input} ${gitlib.libpath} ${gitlib.input.rev}"
    ) gitLibs}
  '';

  # tools.gitlibs calls `git clone` to GITLIBS/_repos even when libs/<sha> is already present (setupGitLibs);
  # fakeGit makes those calls succeed (exit 0).
  # The app's revision string comes from LOGSEQ_REVISION env, not fakeGit.
  fakeGit = writeShellScriptBin "git" ''
    echo "${rev}@nixpkgs"
  '';

  fetchDeps =
    { hash, ... }@args:
    stdenvNoCC.mkDerivation (
      removeAttrs args [ "hash" ]
      // {
        dontFixup = true;
        outputHash = hash;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
      }
    );

  clojureDeps = fetchDeps {
    name = "logseq-${version}-clojure-deps";
    hash = "sha256-rmYvIlJJUAVOdQno5mBvDhL6gEMiIxSTVUJM6FIFEa8=";
    inherit src;

    nativeBuildInputs = [
      clojure
      git
      cacert
    ];

    buildPhase = ''
      export HOME=$(mktemp -d)
      ${setupGitLibs}
      mkdir -p $out/maven
      sed -i '/packageManager/d' package.json
      clj -Sdeps "{:mvn/local-repo \"$out/maven\"}" -P -M:cljs
      (cd deps/db-sync && clj -Sdeps "{:mvn/local-repo \"$out/maven\"}" -P -M:cljs)
      (cd deps/publish && clj -Sdeps "{:mvn/local-repo \"$out/maven\"}" -P -M:cljs)
      find $out/maven -type f \( \
        -name \*.lastUpdated \
        -o -name resolver-status.properties \
        -o -name _remote.repositories \) -delete
    '';
  };

  # Wrapper that routes clojure to the pre-fetched Maven repo.
  clojureWithDeps = writeShellScriptBin "clojure" ''
    exec ${lib.getExe' clojure "clojure"} -Sdeps '{:mvn/local-repo "${clojureDeps}/maven"}' "$@"
  '';

  # Root pnpm deps (for the main app build: gulp, cljs, webpack).
  pnpmDepsRoot = fetchPnpmDeps {
    pname = "logseq";
    inherit src pnpm;
    fetcherVersion = 4;
    hash = "sha256-4mcO6dm9H3pPryLqnw7K+zyVv86HGL+a2hnZNMwBxPo=";
  };

  # UI package pnpm deps (packages/ui) — needed by gulp:build, so every target that runs it (desktop, web app) needs this too.
  pnpmDepsUi = fetchPnpmDeps {
    pname = "logseq-ui";
    inherit src pnpm;
    fetcherVersion = 4;
    prePnpmInstall = "cd packages/ui";
    hash = "sha256-QDu6pz9/gGMo4eptxp9O0LCNQjxlWnNEvaJnvMb+HAE=";
  };

  # deps/db-sync's pnpm deps — shared by both its build targets (sync.nix's
  # plain-Node adapter and sync-worker.nix's Cloudflare Worker build): same
  # package.json/pnpm-lock.yaml, just a different shadow-cljs build id, so one
  # fetch covers both rather than two FODs paying to fetch the same lockfile.
  pnpmDepsSync = mkPnpmDeps {
    pname = "logseq-sync";
    subdir = "deps/db-sync";
    hash = "sha256-tyufXJGTP8n3NaaiVBSeNZOyZLeyuiIqSTUBRonthxA=";
  };

  # An undeclared dependency of deps/db-sync, spliced in by hand — needed by
  # both of deps/db-sync's build targets for the same reason (see sync.nix's
  # original comment on this, kept there rather than duplicated here):
  # logseq/outliner is a :local/root dep whose cljs reaches the ["mldoc"]
  # require, but deps/db-sync/package.json never declares mldoc itself.
  mldocSrc = fetchzip {
    url = "https://registry.npmjs.org/mldoc/-/mldoc-1.5.9.tgz";
    hash = "sha256-KOR8ayGXLCbYvmiRucHTleUvia6GXVa9f921AQwd8Ug=";
  };

  # Upstream's values for everything `clientConfig` can override. The app
  # reads its overrides at runtime (applyClientConfig, below); only the OCaml
  # CLI still needs these, as search strings, and the checks grep bundles for
  # them.
  defaultClientConfig = {
    cognitoClientId = "69cs1lgme7p8kbgld8n5kseii6";
    oauthDomain = "logseq-prod.auth.us-east-1.amazoncognito.com";
    apiDomain = "api.logseq.com";
    cognitoIdp = "https://cognito-idp.us-east-1.amazonaws.com/";
    userPoolId = "us-east-1_dtagLnju8";
    publishApiBase = "https://logseq.io";
    syncWsUrl = "wss://api.logseq.io/sync/%s";
    syncHttpBase = "https://api.logseq.io";
  };

  # The OCaml CLI keeps its own copies of some of those literals.
  cliClientConfigPatches = {
    "cli/lib/auth_state.ml" = [
      "oauthDomain"
      "cognitoClientId"
      "syncHttpBase"
    ];
    "cli/lib/cli_config.ml" = [
      "syncWsUrl"
      "syncHttpBase"
    ];
  };

  applyCliConfig =
    cfg:
    lib.concatStrings (
      lib.mapAttrsToList (file: keys: ''
        substituteInPlace ${file} \
          ${lib.concatMapStringsSep " \\\n  " (
            key: "--replace-fail '\"${defaultClientConfig.${key}}\"' '\"${cfg.${key}}\"'"
          ) keys}
      '') cliClientConfigPatches
    );

  # The app: ./self-hosting.patch makes the client read its identity and
  # endpoint values from js/logseq-config.js at runtime (upstream's where
  # unset), and this bakes `clientConfig` (the overrides only) into that file
  # for web, desktop and mobile alike. A web server may serve its own instead,
  # from the environment (./_webapp-nginx.nix). -F0 so upstream drift fails
  # the build instead of applying fuzzily.
  applyClientConfig =
    clientConfig:
    let
      unknown = lib.subtractLists (lib.attrNames clientConfigKeys) (lib.attrNames clientConfig);
      configJs = writeText "logseq-config.js" "window.LOGSEQ_CONFIG = ${builtins.toJSON clientConfig};\n";
    in
    assert lib.assertMsg (unknown == [ ]) "unknown clientConfig keys: ${toString unknown}";
    ''
      patch -p1 -F0 < ${./self-hosting.patch}
      for dir in resources/js resources/mobile/js; do
        install -Dm644 ${configJs} $dir/logseq-config.js
      done
    '';

  setupSources = { packageJsons }: ''
    export HOME=$(mktemp -d)
    sed -i '/packageManager/d' ${lib.concatStringsSep " " packageJsons}
    ${setupGitLibs}
    ${pnpmStoreHelper}
  '';

  mkPnpmDeps =
    {
      pname,
      subdir,
      hash,
    }:
    fetchPnpmDeps {
      inherit
        pname
        src
        pnpm
        hash
        ;
      fetcherVersion = 4;
      prePnpmInstall = "cd ${subdir}";
      pnpmInstallFlags = [ "--ignore-workspace" ];
    };

  pnpmStoreHelper = ''
    install_pnpm_store() {
      local deps="$1" dir="$2"
      shift 2
      local store
      store=$(mktemp -d)
      tar --zstd -xf "$deps/pnpm-store.tar.zst" -C "$store"
      chmod -R +w "$store"
      if [ -f "$store/v11/index.db.sql" ]; then
        sqlite3 "$store/v11/index.db" < "$store/v11/index.db.sql"
        rm "$store/v11/index.db.sql"
      fi
      (cd "$dir" \
        && pnpm config set store-dir "$store" \
        && pnpm install --offline --frozen-lockfile "$@")
    }
  '';
in
{
  inherit
    version
    rev
    pnpm
    src
    setupGitLibs
    fakeGit
    fetchDeps
    clojureDeps
    clojureWithDeps
    pnpmDepsRoot
    pnpmDepsUi
    pnpmDepsSync
    mldocSrc
    mkPnpmDeps
    defaultClientConfig
    applyClientConfig
    applyCliConfig
    pnpmStoreHelper
    setupSources
    ;
}
