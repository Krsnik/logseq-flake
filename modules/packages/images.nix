# Container images for the three deployable targets, so the self-hosted stack
# can be stood up outside NixOS. Not desktop, not Android — neither is a
# service. ../examples/docker-compose.yml wires the three together.
#
# Nothing here rebuilds the app: each image's contents is the same package
# ./{webapp,sync,publish}.nix already produce, and all three are configured
# from the environment at `docker run` time — the servers natively, the web
# app through its runner (./_webapp-nginx.nix), which writes the client's
# config from LOGSEQ_* variables before starting nginx. So the published
# images are generic; a `clientConfig` override only changes the defaults
# baked into the web app's bundle.
let
  # Plain callPackage functions, as everywhere else here, so `.override` works
  # and the images stay usable from an ordinary overlay.
  webappImage =
    {
      lib,
      dockerTools,
      callPackage,
      logseq-webapp,

      # Baked-in defaults, keys in _client-config.nix; the environment still
      # overrides them per key.
      clientConfig ? { },
    }:
    let
      port = 8080;
      serve = callPackage ./_webapp-nginx.nix { } {
        webapp = logseq-webapp.override { inherit clientConfig; };
        inherit port;
      };
    in
    dockerTools.buildLayeredImage {
      name = "logseq-webapp";
      tag = "latest";
      # fakeNss for the `nobody` nginx would drop workers to. 1777 on /tmp
      # because the compose file runs this container unprivileged instead —
      # cap_drop: ALL takes away the setuid nginx's master would need — and
      # the runner writes the client config and nginx its pid file there.
      contents = [ dockerTools.fakeNss ];
      extraCommands = "mkdir -p tmp && chmod 1777 tmp";
      config = {
        Cmd = [
          (lib.getExe serve)
          "/tmp"
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
      };
    };
}
