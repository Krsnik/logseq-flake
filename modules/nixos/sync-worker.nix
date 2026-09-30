# services.logseq-sync-worker — deps/db-sync's Cloudflare Worker build
# (semantic REST/MCP/ChatGPT-Apps, D1+Durable Object+R2 storage). A
# separate module from services.logseq-sync, not a `variant` option on it:
# the two have incompatible storage, not two frontends onto one dataset.
#
# No D1-migration option: the package's own launcher already runs
# `wrangler d1 migrations apply` before `wrangler dev` unconditionally —
# structural, like publish's CLOUDFLARE_INCLUDE_PROCESS_ENV, not something
# a deployment needs to differ.
{ self, ... }:
{
  flake.nixosModules.logseq-sync-worker =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.logseq-sync-worker;
      common = import ./_common.nix { inherit lib; };
    in
    {
      options.services.logseq-sync-worker =
        (common.mkServiceOptions {
          name = "logseq-sync-worker";
          defaultPort = 8787;
        })
        // common.oidcOptions
        // (common.mkR2Options "logseq-sync-worker-local")
        // {
          publicUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "https://sync.example.org";
            description = ''
              The URL clients reach the worker at, when that isn't its own
              listen address (a TLS reverse proxy). MCP clients need it:
              the OAuth metadata they check is built from it.
            '';
          };
          dataDir = common.mkDataDirOption cfg;
          package = lib.mkOption {
            type = lib.types.package;
            defaultText = "inputs.logseq.packages.\${system}.logseq-sync-worker";
            default = self.packages.${pkgs.stdenv.hostPlatform.system}.logseq-sync-worker;
            description = "The logseq-sync-worker package to run.";
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
            SYNC_WORKER_PORT = toString cfg.port;
            SYNC_WORKER_DATA_DIR = cfg.dataDir;
            R2_ACCOUNT_ID = cfg.r2AccountId;
            R2_BUCKET = cfg.r2Bucket;
            R2_ACCESS_KEY_ID = cfg.r2AccessKeyId;
            R2_SECRET_ACCESS_KEY = cfg.r2SecretAccessKey;
            SYNC_WORKER_PUBLIC_URL = lib.mkIf (cfg.publicUrl != null) cfg.publicUrl;
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
