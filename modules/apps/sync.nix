{
  perSystem = { pkgs, config, ... }: {
    apps.logseq-sync = {
      type = "app";
      program = pkgs.lib.getExe (
        pkgs.writeShellApplication {
          name = "logseq-sync-run";
          runtimeInputs = [ config.packages.logseq-sync ];
          text = ''
            if [ -z "''${DB_SYNC_DATA_DIR:-}" ]; then
                dir=$(mktemp -d)
                trap 'rm -rf "$dir"' EXIT
                export DB_SYNC_DATA_DIR="$dir"
                echo "[logseq-sync][warning] Scratch data dir: $dir (discarded on exit)" >&2
            fi
            export DB_SYNC_PORT="''${DB_SYNC_PORT:-8080}"
            exec logseq-sync
          '';
        }
      );
    };
  };
}
