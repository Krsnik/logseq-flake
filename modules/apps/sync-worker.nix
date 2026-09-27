{
  perSystem = { pkgs, config, ... }: {
    apps.logseq-sync-worker = {
      type = "app";
      program = pkgs.lib.getExe (
        pkgs.writeShellApplication {
          name = "logseq-sync-worker-run";
          runtimeInputs = [ config.packages.logseq-sync-worker ];
          text = ''
            if [ -z "''${SYNC_WORKER_DATA_DIR:-}" ]; then
                dir=$(mktemp -d)
                trap 'rm -rf "$dir"' EXIT
                export SYNC_WORKER_DATA_DIR="$dir"
                echo "[logseq-sync-worker][warning] Scratch data dir: $dir (discarded on exit)" >&2
            fi
            export SYNC_WORKER_PORT="''${SYNC_WORKER_PORT:-8787}"
            exec logseq-sync-worker
          '';
        }
      );
    };
  };
}
