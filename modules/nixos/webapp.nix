# services.logseq-webapp — bundles its own dedicated nginx process (reusing
# ../packages/_webapp-nginx.nix's recipe verbatim, the same one the
# container image and `nix run` wrapper use), rather than leaving that to
# the consumer the way every other service in this configuration does. The
# one deliberate exception: there's no backend to proxy to here —
# nginx-serving-static-files *is* the service, not an optional layer in
# front of one. A real deployment wanting a public domain/TLS still fronts
# this with an ordinary reverse-proxy vhost of its own, same as any other
# service here — this module only owns getting the static bundle served
# correctly (the wasm mime type, the SPA fallback), not domain routing.
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

      conf = pkgs.callPackage ../packages/_webapp-nginx.nix { } {
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
            description = ''
              The logseq-webapp package to serve. Identity-provider/sync/
              publish endpoints are a build-time concern (clientConfig), not
              a service option — override this package
              (`.override { clientConfig = {...}; }`) to point the client at
              a self-hosted IdP or sync/publish server.
            '';
          };
        };

      config = lib.mkIf cfg.enable {
        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

        systemd.services.${cfg.serviceName} = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

          serviceConfig = common.mkUserServiceConfig cfg // {
            ExecStart = "${lib.getExe' pkgs.nginx "nginx"} -c ${conf} -p /var/lib/${cfg.serviceName}/ -e stderr";
            StateDirectory = cfg.serviceName;
            Restart = "on-failure";
          };
        };
      };
    };
}
