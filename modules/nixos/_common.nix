# Shared option/hardening shapes for the four services.logseq-* modules.
# Not itself a flake-parts module (the `_` prefix) — a plain helper, called
# via `import ./_common.nix { inherit lib; }` from each module's own
# `options.services.logseq-<name>` definition, same spirit as
# ../packages/_common.nix but for NixOS module boilerplate instead of Nix
# package boilerplate.
{ lib }:
{
  # Every module's common option surface, minus `package` (each module's
  # default points at its own `self.packages.${system}.logseq-<name>`,
  # which needs `self` closed over from that module's own outer scope, so
  # it can't live here).
  mkServiceOptions =
    { name, defaultPort }:
    {
      enable = lib.mkEnableOption "the ${name} service";

      serviceName = lib.mkOption {
        type = lib.types.str;
        description = "Systemd service name, for cross-referencing from another module.";
        defaultText = name;
        default = name;
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = defaultPort;
        description = "Port to listen on.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to open the firewall for `port`.";
      };

      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Run as this fixed user instead of a `DynamicUser`. Needed on a host
          where a `DynamicUser`'s allocated UID doesn't survive reboot (an
          impermanent root), which would otherwise make ownership of the
          state directory drift every boot.
        '';
      };

      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Group to run as, if `user` is set. Defaults to the same name as `user`.";
      };
    };

  # The serviceConfig fragment implementing user/group's DynamicUser escape
  # hatch described above — merge into the module's own serviceConfig.
  mkUserServiceConfig =
    cfg:
    {
      DynamicUser = cfg.user == null;
    }
    // lib.optionalAttrs (cfg.user != null) {
      User = cfg.user;
      Group = if cfg.group != null then cfg.group else cfg.user;
    };

  # Where a server keeps its data. Under /var/lib (the usual case, nested
  # paths included) systemd creates it and hands it to the service user via
  # StateDirectory, which also orders the service after the mount holding it
  # (systemd.exec(5)). Anywhere else it has to exist, writable by `user`, and
  # the modules' explicit RequiresMountsFor does that ordering instead.
  mkDataDirOption =
    cfg:
    lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/${cfg.serviceName}";
      defaultText = lib.literalExpression ''"/var/lib/''${serviceName}"'';
      example = "/var/lib/logseq/sync";
      description = "Directory the server keeps its data in.";
    };

  mkDataDirServiceConfig =
    cfg:
    if lib.hasPrefix "/var/lib/" cfg.dataDir then
      { StateDirectory = lib.removePrefix "/var/lib/" cfg.dataDir; }
    else
      { ReadWritePaths = [ cfg.dataDir ]; };

  # Shared by the two servers (sync, sync-worker, publish all read these —
  # sync-worker/publish additionally need R2, see mkR2Options). No default:
  # fails loudly if unset, matching examples/docker-compose.yml's existing
  # ${LOGSEQ_OIDC_ISSUER:?set LOGSEQ_OIDC_ISSUER} philosophy.
  oidcOptions = {
    oidcIssuer = lib.mkOption {
      type = lib.types.str;
      description = "OIDC issuer URL; compared to the token's `iss` claim with `=`, so it must match exactly.";
    };

    oidcClientId = lib.mkOption {
      type = lib.types.str;
      description = "Expected `aud` (or `client_id`) claim.";
    };

    oidcJwksUrl = lib.mkOption {
      type = lib.types.str;
      description = "Signing keys endpoint, fetched on the first authenticated request and cached.";
    };
  };

  # sync-worker and publish both bind R2 for asset storage but, run against
  # wrangler's local runtime, there's no real R2 endpoint to reach — these
  # are placeholders that keep the signing code happy, same as
  # examples/keycloak.nix's existing publish-side ones.
  mkR2Options = defaultBucket: {
    r2AccountId = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = "R2 account id. A real value only matters if something outside this host needs to read the bucket directly.";
    };

    r2Bucket = lib.mkOption {
      type = lib.types.str;
      default = defaultBucket;
      description = "R2 bucket name.";
    };

    r2AccessKeyId = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = "R2 access key id.";
    };

    r2SecretAccessKey = lib.mkOption {
      type = lib.types.str;
      default = "local";
      description = "R2 secret access key.";
    };
  };
}
