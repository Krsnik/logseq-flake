# Container images for the three deployable targets, so the self-hosted stack
# can be stood up outside NixOS. Not desktop, not Android — neither is a
# service. ../examples/docker-compose.yml wires the three together.
#
# Nothing here rebuilds the app: each image's contents is the same package
# ./{webapp,sync,publish}.nix already produce. The config split carries over
# unchanged, and deliberately so:
#
#   * Both servers read their config from the environment, so it maps straight
#     onto compose `environment:` entries.
#   * The web app's endpoints are compiled into its bundle, so the image takes
#     the same `clientConfig` argument the package does and passes it through.
#     No runtime config path is bolted on just for containers — there would then
#     be two mechanisms to keep in sync, and the bundle is long compiled by the
#     time a container starts.
let
  # Plain callPackage functions, as everywhere else here, so `.override` works
  # and the images stay usable from an ordinary overlay.
  webappImage =
    {
      lib,
      dockerTools,
      callPackage,
      nginx,
      logseq-webapp,

      # Same keys as the package's; see _common.nix's defaultClientConfig.
      clientConfig ? { },
    }:
    let
      webapp = logseq-webapp.override { inherit clientConfig; };
      port = 8080;

      # Shared with ../apps/webapp.nix's `nix run` wrapper — see its header for
      # why the conf's paths are relative rather than hardcoded to /tmp.
      conf = callPackage ./_webapp-nginx.nix { } { inherit webapp port; };
    in
    dockerTools.buildLayeredImage {
      name = "logseq-webapp";
      tag = "latest";
      # fakeNss for the `nobody` nginx would drop workers to. 1777 on /tmp
      # because the compose file runs this container unprivileged instead —
      # cap_drop: ALL takes away the setuid nginx's master would need — and
      # nginx writes its pid file there at startup.
      contents = [ dockerTools.fakeNss ];
      extraCommands = "mkdir -p tmp && chmod 1777 tmp";
      config = {
        Cmd = [
          (lib.getExe' nginx "nginx")
          "-c"
          "${conf}"
          # The conf's pid/temp paths are relative to this: the image's own
          # /tmp (see extraCommands above), same effective layout as before
          # this was factored out to be shared with the `nix run` wrapper.
          "-p"
          "/tmp/"
          # nginx opens its compile-time default error log before it parses the
          # config, so without this every start logs a bogus `could not open
          # error log file /var/log/nginx/error.log` alert and then carries on
          # using the configured one. -e applies before config parsing. The
          # bare keyword, not a path — see _webapp-nginx.nix's error_log
          # comment for why.
          "-e"
          "stderr"
        ];
        ExposedPorts."${toString port}/tcp" = { };
      };
    };

  syncImage =
    {
      lib,
      dockerTools,
      logseq-sync,
    }:
    dockerTools.buildLayeredImage {
      name = "logseq-sync";
      tag = "latest";
      # caCertificates so the JWKS fetch reaches an https issuer; without it
      # every authenticated request fails at certificate verification.
      contents = [ dockerTools.caCertificates ];
      extraCommands = "mkdir -p tmp var/lib/logseq-sync";
      config = {
        Cmd = [ (lib.getExe logseq-sync) ];
        Env = [ "DB_SYNC_PORT=8080" ];
        ExposedPorts."8080/tcp" = { };
        Volumes."/var/lib/logseq-sync" = { };
      };
    };

  # ponytail: ~2.6GB, almost all of it nixpkgs' wrangler — which is the upstream
  # pnpm *monorepo* (2.2GiB: three workerd builds at ~118MB each, plus
  # vitest/typescript/turbo/every-platform esbuild), of which one workerd and
  # one package are used at runtime. If the size ever matters, trim it there;
  # nothing else in this image is large.
  publishImage =
    {
      lib,
      dockerTools,
      logseq-publish,
    }:
    dockerTools.buildLayeredImage {
      name = "logseq-publish";
      tag = "latest";
      contents = [ dockerTools.caCertificates ];
      extraCommands = "mkdir -p tmp var/lib/logseq-publish";
      config = {
        Cmd = [ (lib.getExe logseq-publish) ];
        ExposedPorts."8787/tcp" = { };
        Volumes."/var/lib/logseq-publish" = { };
      };
    };
in
{
  perSystem =
    { pkgs, config, ... }:
    {
      packages = {
        logseq-webapp-image = pkgs.callPackage webappImage {
          inherit (config.packages) logseq-webapp;
        };
        logseq-sync-image = pkgs.callPackage syncImage {
          inherit (config.packages) logseq-sync;
        };
        logseq-publish-image = pkgs.callPackage publishImage {
          inherit (config.packages) logseq-publish;
        };

        # A Docker-native front door onto logseq-webapp-image's own
        # clientConfig, for consumers who'd rather set --build-arg than learn
        # Nix override syntax — see examples/docker-build/. Kept as a
        # separate package (not the plain image with a default file baked
        # in) so checks.containers, which builds logseq-webapp-image
        # directly, stays untouched by this experimental path.
        logseq-webapp-docker-image = config.packages.logseq-webapp-image.override {
          clientConfig = builtins.fromJSON (
            builtins.readFile ../../examples/docker-build/client-config.json
          );
        };
      };
    };
}
