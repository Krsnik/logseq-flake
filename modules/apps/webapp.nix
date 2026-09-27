{
  perSystem = { pkgs, config, ... }: {
    apps.logseq-webapp = {
      type = "app";
      program =
        let
          port = 8080;
          conf = pkgs.callPackage ../packages/_webapp-nginx.nix { } {
            webapp = config.packages.logseq-webapp;
            inherit port;
          };
        in
        pkgs.lib.getExe (
          pkgs.writeShellApplication {
            name = "logseq-webapp-run";
            runtimeInputs = [ pkgs.nginx ];
            text = ''
              dir=$(mktemp -d)
              trap 'rm -rf "$dir"' EXIT
              echo "logseq-webapp: serving on http://127.0.0.1:${toString port}" >&2
              exec nginx -c ${conf} -p "$dir/" -e stderr
            '';
          }
        );
    };
  };
}
