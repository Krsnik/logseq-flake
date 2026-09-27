{ self, ... }: {
  flake.nixosModules.logseq =
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
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];
      };
    };
}
