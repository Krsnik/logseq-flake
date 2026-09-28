# services.logseq-webapp — bundles its own dedicated nginx process (reusing
# ../packages/_webapp-nginx.nix's runner verbatim, the same one the
# container image and `nix run` wrapper use), rather than leaving that to
# the consumer the way every other service in this configuration does. The
# one deliberate exception: there's no backend to proxy to here —
# nginx-serving-static-files *is* the service, not an optional layer in
# front of one. A real deployment wanting a public domain/TLS still fronts
# this with an ordinary reverse-proxy vhost of its own, same as any other
# service here — this module only owns getting the static bundle served
# correctly (the wasm mime type, the user_info stub, the client config), not
# domain routing.
{ self, ... }:
{
  flake.nixosModules.logseq-webapp =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.logseq-webapp;
      common = import ./_common.nix { inherit lib; };
      envVars = import ../packages/_client-config.nix;

      serve = pkgs.callPackage ../packages/_webapp-nginx.nix { } {
        webapp = cfg.package;
        inherit (cfg) port;
      };
    in
    {
      options.services.logseq-webapp =
        (common.mkServiceOptions {
          name = "logseq-webapp";
          defaultPort = 8080;
        })
        // {
          package = lib.mkOption {
            type = lib.types.package;
            defaultText = "inputs.logseq.packages.\${system}.logseq-webapp";
            default = self.packages.${pkgs.stdenv.hostPlatform.system}.logseq-webapp;
            description = "The logseq-webapp package to serve.";
          };

          clientConfig = lib.mkOption {
            # One option per key, so a typo fails evaluation instead of being
            # silently ignored by the client.
            type = lib.types.submodule {
              options = lib.mapAttrs (
                key: var:
                lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "`${key}`; ${var} in the container image.";
                }
              ) envVars;
            };
            default = { };
            example = {
              oidcIssuer = "https://id.example.org/realms/logseq";
              cognitoClientId = "logseq";
              apiDomain = "notes.example.org";
            };
            description = ''
              Identity provider and sync/publish endpoints, served to the
              client at runtime, so changing them restarts nginx rather than
              rebuilding `package`. Unset keys keep the package's baked-in
              values, then upstream's.
            '';
          };
        };

      config = lib.mkIf cfg.enable {
        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

        systemd.services.${cfg.serviceName} = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

          # The runner reads the same LOGSEQ_* variables as the container image.
          environment = lib.mapAttrs' (key: lib.nameValuePair envVars.${key}) (
            lib.filterAttrs (_: value: value != null) cfg.clientConfig
          );

          serviceConfig = common.mkUserServiceConfig cfg // {
            ExecStart = "${lib.getExe serve} /var/lib/${cfg.serviceName}";
            StateDirectory = cfg.serviceName;
            Restart = "on-failure";
          };
        };
      };
    };
}
