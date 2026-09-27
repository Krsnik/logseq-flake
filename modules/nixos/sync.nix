# services.logseq-sync — deps/db-sync's plain-Node adapter (SQLite/
# filesystem storage). See modules/packages/sync-worker.nix's own module
# (sync-worker.nix, this directory) for the Cloudflare-Worker variant —
# deliberately a separate module, not a `variant` option on this one:
# incompatible storage, not two frontends onto one dataset.
{ self, ... }:
{
  flake.nixosModules.logseq-sync =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.logseq-sync;
      common = import ./_common.nix { inherit lib; };
    in
    {
      options.services.logseq-sync =
        (common.mkServiceOptions {
          name = "logseq-sync";
          defaultPort = 8080;
        })
        // common.oidcOptions
        // {
          package = lib.mkOption {
            type = lib.types.package;
            defaultText = "inputs.logseq.packages.\${system}.logseq-sync";
            default = self.packages.${pkgs.stdenv.hostPlatform.system}.logseq-sync;
            description = "The logseq-sync package to run.";
          };
        };

      config = lib.mkIf cfg.enable {
        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

        systemd.services.${cfg.serviceName} = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

          environment = {
            COGNITO_ISSUER = cfg.oidcIssuer;
            COGNITO_CLIENT_ID = cfg.oidcClientId;
            COGNITO_JWKS_URL = cfg.oidcJwksUrl;
            DB_SYNC_PORT = toString cfg.port;
            DB_SYNC_DATA_DIR = "/var/lib/${cfg.serviceName}";
          };

          serviceConfig = common.mkUserServiceConfig cfg // {
            ExecStart = lib.getExe cfg.package;
            StateDirectory = cfg.serviceName;
            Restart = "on-failure";
          };
        };
      };
    };
}
