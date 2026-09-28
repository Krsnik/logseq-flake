{
  perSystem =
    { pkgs, config, ... }:
    {
      # Configured like the container image: LOGSEQ_* variables in the
      # environment (see ../packages/_client-config.nix), e.g.
      #   LOGSEQ_OIDC_ISSUER=https://id.example.org/realms/logseq nix run .#logseq-webapp
      apps.logseq-webapp = {
        type = "app";
        program = pkgs.lib.getExe (
          pkgs.writeShellApplication {
            name = "logseq-webapp-run";
            text = ''
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
