{ self, ... }: {
  flake.homeModules.logseq =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.logseq;
    in
    {
      options.programs.logseq = {
        enable = lib.mkEnableOption "Logseq, knowledge management platform";

        package = lib.mkPackageOption self.packages.${pkgs.stdenv.hostPlatform.system} "logseq" {
          pkgsText = "self.packages";
          extraDescription = ''
            Override for a custom `clientConfig` (`.override { clientConfig = {...}; }`)
            to point it at a self-hosted identity provider or sync/publish server.
          '';
        };

        autostart = lib.mkOption {
          type = lib.types.bool;
          default = false;
          example = true;
          description = ''
            Whether to start Logseq automatically on login through the XDG autostart mechanism.
            Also requires `xdg.autostart.enable`.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.autostart -> config.xdg.autostart.enable;
            message = ''
              `xdg.autostart.enable` has to be enabled for `programs.logseq.autostart` to be effective.
            '';
          }
        ];

        home.packages = [ cfg.package ];

        xdg.autostart.entries = lib.mkIf cfg.autostart [
          "${cfg.package}/share/applications/Logseq.desktop"
        ];
      };
    };
}
