{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.trek;

  fingerprint = pkgs.writeShellScript "trek-environment-fingerprint" ''
    set -eu
    ${pkgs.coreutils}/bin/stat -L --printf='%d:%i:%s:%y:%z\n' ${lib.escapeShellArg cfg.environmentFile}
    ${pkgs.coreutils}/bin/sha256sum < ${lib.escapeShellArg cfg.environmentFile}
  '';
  recordEnvironment = pkgs.writeShellScript "trek-environment-record" ''
    set -eu
    umask 077
    ${fingerprint} > /run/trek-environment/fingerprint
  '';
  checkEnvironment = pkgs.writeShellScript "trek-environment-check" ''
    set -eu
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet trek.service; then
      exit 0
    fi
    current="$(${fingerprint})"
    previous="$(${pkgs.coreutils}/bin/cat /run/trek-environment/fingerprint)"
    if [ "$current" != "$previous" ]; then
      ${pkgs.systemd}/bin/systemctl try-restart trek.service
    fi
  '';
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

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/trek";
      example = "/var/lib/travel/trek";
      description = ''
        Absolute state and working directory beneath /var/lib.
        Systemd creates it for the service's dynamic user.
        Components may contain ASCII letters, digits, dots, underscores and hyphens.
      '';
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
        Changes are checked periodically and restart the running service.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.match "/var/lib/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*" cfg.stateDir != null
          && builtins.all (part: part != "." && part != "..") (lib.splitString "/" cfg.stateDir)
          && cfg.stateDir != "/var/lib/private"
          && !lib.hasPrefix "/var/lib/private/" cfg.stateDir;
        message = "services.trek.stateDir must be a normalized directory beneath /var/lib, outside /var/lib/private, with only ASCII letters, digits, dots, underscores and hyphens in its components.";
      }
    ];

    systemd.services.trek = {
      description = "TREK travel planner";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = cfg.settings // {
        NODE_ENV = "production";
        HOST = cfg.host;
        PORT = toString cfg.port;
        TREK_STATE_DIR = cfg.stateDir;
      };
      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        DynamicUser = true;
        StateDirectory = lib.removePrefix "/var/lib/" cfg.stateDir;
        StateDirectoryMode = "0700";
        WorkingDirectory = cfg.stateDir;
        Restart = "on-failure";
        UMask = "0077";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      } // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = cfg.environmentFile;
        ExecStartPre = "+${recordEnvironment}";
      };
    };

    systemd.tmpfiles.rules = lib.optionals (cfg.environmentFile != null) [
      "d /run/trek-environment 0700 root root -"
    ];

    systemd.timers.trek-environment = lib.mkIf (cfg.environmentFile != null) {
      description = "Check the TREK environment file";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitInactiveSec = "1min";
        AccuracySec = "1s";
      };
    };

    systemd.services.trek-environment = lib.mkIf (cfg.environmentFile != null) {
      description = "Check for TREK environment file changes";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = checkEnvironment;
      };
    };
  };
}
