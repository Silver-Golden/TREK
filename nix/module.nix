{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.trek;
in
{
  options.services.trek = {
    enable = lib.mkEnableOption "TREK travel planner";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "TREK package to run.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address on which TREK listens.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3001;
      description = "Port on which TREK listens.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Non-secret environment variables from server/.env.example.
        These values are world-readable in the Nix store; use environmentFile
        for secrets.
      '';
      example = {
        APP_URL = "https://trek.example.org";
        ALLOWED_ORIGINS = "https://trek.example.org";
      };
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/trek.env";
      description = ''
        Path to a systemd EnvironmentFile containing secrets.
        Not copied into the Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.trek = {
      description = "TREK travel planner";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = cfg.settings // {
        NODE_ENV = "production";
        HOST = cfg.host;
        PORT = toString cfg.port;
        TREK_STATE_DIR = "/var/lib/trek";
      };
      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        DynamicUser = true;
        StateDirectory = "trek";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/trek";
        Restart = "on-failure";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
      };
    };
  };
}
