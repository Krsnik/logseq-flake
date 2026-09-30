# services.logseq-publish — deps/publish's Cloudflare Worker on wrangler's
# local runtime (Durable Object + R2, no D1).
{ self, ... }:
{
  flake.nixosModules.logseq-publish =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.logseq-publish;
      common = import ./_common.nix { inherit lib; };
    in
    {
      options.services.logseq-publish =
        (common.mkServiceOptions {
          name = "logseq-publish";
          defaultPort = 8787;
        })
        // common.oidcOptions
        // (common.mkR2Options "logseq-publish-local")
        // {
          dataDir = common.mkDataDirOption cfg;
          package = lib.mkOption {
            type = lib.types.package;
            defaultText = "inputs.logseq.packages.\${system}.logseq-publish";
            default = self.packages.${pkgs.stdenv.hostPlatform.system}.logseq-publish;
            description = "The logseq-publish package to run.";
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
            PUBLISH_PORT = toString cfg.port;
            PUBLISH_DATA_DIR = cfg.dataDir;
            R2_ACCOUNT_ID = cfg.r2AccountId;
            R2_BUCKET = cfg.r2Bucket;
            R2_ACCESS_KEY_ID = cfg.r2AccessKeyId;
            R2_SECRET_ACCESS_KEY = cfg.r2SecretAccessKey;
          };

          unitConfig.RequiresMountsFor = [ cfg.dataDir ];

          serviceConfig = common.mkUserServiceConfig cfg // common.mkDataDirServiceConfig cfg // {
            ExecStart = lib.getExe cfg.package;
            Restart = "on-failure";
          };
        };
      };
    };
}
