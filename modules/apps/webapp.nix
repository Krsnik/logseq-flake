{
  perSystem =
    { pkgs, config, ... }:
    {
      # Configured like the container image: LOGSEQ_* variables (see
      # ../packages/_client-config.nix), from the environment or a .env in the
      # current directory (../../examples/.env.example), e.g.
      #   LOGSEQ_OIDC_ISSUER=https://id.example.org/realms/logseq nix run .#logseq-webapp
      apps.logseq-webapp = {
        type = "app";
        program = pkgs.lib.getExe (
          pkgs.writeShellApplication {
            name = "logseq-webapp-run";
            text = ''
              # Like docker compose: the file fills in, and variables already
              # in the environment win, so they're saved and restored around it.
              # ''${!LOGSEQ_@}, not compgen: the bash this runs under has no
              # completion builtins.
              if [ -f .env ]; then
                given=""
                for var in "''${!LOGSEQ_@}"; do
                  given+="$(declare -p "$var");"
                done
                set -a
                # shellcheck source=/dev/null
                . ./.env
                set +a
                eval "$given"
              fi

              dir=$(mktemp -d)
              echo "logseq-webapp: serving on http://localhost:8080" >&2
              exec ${
                pkgs.lib.getExe (
                  pkgs.callPackage ../packages/_webapp-nginx.nix { } { webapp = config.packages.logseq-webapp; }
                )
              } "$dir"
            '';
          }
        );
      };
    };
}
