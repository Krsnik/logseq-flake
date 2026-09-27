{
  perSystem = { pkgs, config, ... }: {
    apps.logseq-publish = {
      type = "app";
      program = pkgs.lib.getExe (
        pkgs.writeShellApplication {
          name = "logseq-publish-run";
          runtimeInputs = [ config.packages.logseq-publish ];
          text = ''
            if [ -z "''${PUBLISH_DATA_DIR:-}" ]; then
                dir=$(mktemp -d)
                trap 'rm -rf "$dir"' EXIT
                export PUBLISH_DATA_DIR="$dir"
                echo "[logseq-publish][warning] Scratch data dir: $dir (discarded on exit)" >&2
            fi
            export PUBLISH_PORT="''${PUBLISH_PORT:-8787}"
            exec logseq-publish
          '';
        }
      );
    };
  };
}
