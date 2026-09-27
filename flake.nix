{
  description = "Logseq for Nix: desktop client, web app, sync server and Android app";

  inputs = {
    import-tree.url = "github:denful/import-tree";

    flake-parts.url = "github:hercules-ci/flake-parts";

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The pinned Logseq source and its git-lib dependencies (deps.edn's
    # :git/sha deps, superset of every subproject's own deps.edn), as flake
    # inputs rather than fetchFromGitHub calls buried in _common.nix: every
    # pin now lives in flake.lock (one place, auto-managed — no more hand-
    # maintained `hash = "sha256-..."` strings to keep in sync), and any of
    # them is overridable from the CLI (`--override-input hsx-src ...`)
    # without editing a single .nix file.
    logseq-src = {
      url = "github:logseq/logseq/2.0.1";
      flake = false;
    };
    hsx-src = {
      url = "github:logseq/hsx/21615ffa2aa530cc830e3464b793a53ef4fdd18c";
      flake = false;
    };
    datascript-src = {
      url = "github:logseq/datascript/3f141af97b70e1f14c65eaa119acd822ebece37e";
      flake = false;
    };
    cljs-time-src = {
      url = "github:logseq/cljs-time/5704fbf48d3478eedcf24d458c8964b3c2fd59a9";
      flake = false;
    };
    glogi-src = {
      url = "github:lambdaisland/glogi/30328a045141717aadbbb693465aed55f0904976";
      flake = false;
    };
    logseq-schema-src = {
      url = "github:logseq/logseq-schema/6eeb51cd6d80bbffa0873c1e79790dc1f4ff68cf";
      flake = false;
    };
    malli-src = {
      url = "github:metosin/malli/52ea58a36ff5172b38dfc526ca638afa7226a4a0";
      flake = false;
    };
    cljc-fsrs-src = {
      url = "github:open-spaced-repetition/cljc-fsrs/eeef3520df664e51c3d0ba2031ec2ba071635442";
      flake = false;
    };
    cljs-http-missionary-src = {
      url = "github:RCmerci/cljs-http-missionary/d61ce7e29186de021a2a453a8cee68efb5a88440";
      flake = false;
    };
    clj-fractional-indexing-src = {
      url = "github:logseq/clj-fractional-indexing/1087f0fb18aa8e25ee3bbbb0db983b7a29bce270";
      flake = false;
    };
    rfx-src = {
      url = "github:logseq/rfx/d37aaceb37fcaf969c5cd04646dfdb985d65d3c2";
      flake = false;
    };
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree ./modules);
}
