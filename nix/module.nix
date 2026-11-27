{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.trek;
  managedPostgres = cfg.database == "postgresql";
  usePostgres = cfg.database != "sqlite";
  # Connect using TREK's own PostgreSQL configuration so sockets, credentials and TLS match the move command. 
  # A table in the current schema or a plugin schema makes the target nonempty, connection errors stop service startup.
  targetCheck = pkgs.writeText "trek-target-check.cjs" ''
    const { createRequire } = require('node:module');
    const load = createRequire('${cfg.package}/lib/trek/server/dist/move-to-postgres.js');
    load('reflect-metadata');
    load('tsconfig-paths/register');
    const { readEnv } = load('./app-config');
    const { buildOrmConfig, resolveEngine } = load('./db/engine');
    const { MikroORM } = load('@mikro-orm/core');
    async function main() {
      const config = buildOrmConfig(resolveEngine(readEnv().db));
      const orm = await MikroORM.init({
        ...config, entities: [], entitiesTs: [],
        discovery: { warnWhenNoEntities: false },
        migrations: { ...config.migrations, silent: true },
      });
      try {
        const [result] = await orm.em.getConnection().execute(
          "select exists (select 1 from information_schema.tables where table_schema = current_schema()) or " +
          "exists (select 1 from pg_namespace where starts_with(nspname, 'trek_plugin_')) as occupied"
        );
        process.stdout.write(result.occupied ? 'occupied' : 'empty');
      } finally {
        await orm.close(true);
      }
    }
    main().catch((error) => {
      console.error('Cannot inspect PostgreSQL target:', error.message);
      process.exitCode = 1;
    });
  '';
  # Move existing SQLite data only when the PostgreSQL target is empty.
  migrate = pkgs.writeShellScript "trek-migration-preflight" ''
    set -eu
    source_file="''${1:-$TREK_STATE_DIR/data/travel.db}"
    if [ ! -e "$source_file" ]; then exit 0; fi
    if [ ! -f "$source_file" ] || [ ! -r "$source_file" ]; then
      echo "Cannot read SQLite source: $source_file" >&2
      exit 1
    fi
    if [ ! -s "$source_file" ]; then exit 0; fi
    case "''${RESTORE_FROM_BACKUP:-}" in
      *[![:space:]]*) echo "SQLite data and RESTORE_FROM_BACKUP are both present. Choose one before starting TREK." >&2; exit 1 ;;
    esac
    export TS_NODE_PROJECT="''${TS_NODE_PROJECT:-${cfg.package}/lib/trek/server/tsconfig.json}"
    target="$(${pkgs.nodejs_24}/bin/node ${targetCheck})"
    if [ "$target" = occupied ]; then
      echo "PostgreSQL target is not empty; skipping the SQLite move."
      exit 0
    fi
    if [ "$target" != empty ]; then
      echo "Could not determine whether the PostgreSQL target is empty." >&2
      exit 1
    fi
    exec ${cfg.package}/bin/trek-move-to-postgres "--from=$source_file"
  '';

  socketDirectories = map lib.strings.trim (lib.splitString "," (config.services.postgresql.settings.unix_socket_directories or "/run/postgresql"));
  socketDirectory = builtins.head (socketDirectories ++ [ "" ]);
  databaseUrl = "postgresql://trek@localhost/trek?host=${lib.escapeURL socketDirectory}&port=${toString config.services.postgresql.settings.port}&sslmode=disable";
  # Validate the selected backend and prepare its environment before starting TREK or the move.
  launch = pkgs.writeShellScript "trek-nixos-launch" ''
    set -eu
    ${if managedPostgres then ''
      case "''${TREK_DB_URL:-}" in
        *[![:space:]]*) echo "services.trek.database = postgresql conflicts with TREK_DB_URL." >&2; exit 1 ;;
      esac
      export TREK_DB_URL=${lib.escapeShellArg databaseUrl}
    '' else if usePostgres then ''
      case "''${TREK_DB_URL:-}" in
        *[![:space:]]*) ;;
        *) echo "TREK_DB_URL is required for external PostgreSQL." >&2; exit 1 ;;
      esac
    '' else ''
      case "''${TREK_DB_URL:-}" in
        *[![:space:]]*) echo "TREK_DB_URL conflicts with the SQLite backend." >&2; exit 1 ;;
      esac
      unset TREK_DB_URL
    ''}
    ${lib.optionalString usePostgres ''
      if [ "$1" = ${lib.escapeShellArg migrate} ] && [ -n "''${TREK_DB_FILE:-}" ]; then
        set -- "$@" "$TREK_DB_FILE"
      fi
      unset TREK_DB_FILE TREK_DB_JOURNAL_MODE TREK_DB_SYNCHRONOUS
    ''}
    exec "$@"
  '';

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

    database = lib.mkOption {
      type = lib.types.enum [ "postgresql" "external-postgresql" "sqlite" ];
      default = "postgresql";
      description = "Database backend: managed PostgreSQL, external PostgreSQL using TREK_DB_URL, or SQLite.";
    };

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
        Systemd creates it for the service user.
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
      {
        assertion = !managedPostgres || (lib.versionAtLeast config.services.postgresql.package.version "14" && lib.versionOlder config.services.postgresql.package.version "19");
        message = "services.trek.database = postgresql requires PostgreSQL 14 through 18.";
      }
      {
        assertion = cfg.database == "external-postgresql" || !(cfg.settings ? TREK_DB_URL) || lib.strings.trim cfg.settings.TREK_DB_URL == "";
        message = "services.trek.database conflicts with services.trek.settings.TREK_DB_URL.";
      }
      {
        assertion = !managedPostgres || builtins.match "/[A-Za-z0-9_./-]+" socketDirectory != null;
        message = "services.trek.database = postgresql requires an absolute PostgreSQL Unix socket directory containing only ASCII letters, digits, dots, underscores, slashes and hyphens.";
      }
    ];

    services.postgresql = lib.mkIf managedPostgres {
      enable = true;
      ensureDatabases = [ "trek" ];
      ensureUsers = [ {
        name = "trek";
        ensureDBOwnership = true;
        ensureClauses = { login = true; superuser = false; createdb = false; createrole = false; };
      } ];
    };
    systemd.services.postgresql-setup.environment.PGHOST = lib.mkIf managedPostgres (lib.mkDefault socketDirectory);
    
    users.users.trek = lib.mkIf managedPostgres {
      isSystemUser = true;
      group = "trek";
    };
    users.groups.trek = lib.mkIf managedPostgres { };

    systemd.services.trek = {
      description = "TREK travel planner";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ] ++ lib.optional managedPostgres "postgresql-setup.service";
      requires = lib.optional managedPostgres "postgresql-setup.service";
      environment = cfg.settings // {
        NODE_ENV = "production";
        HOST = cfg.host;
        PORT = toString cfg.port;
        TREK_STATE_DIR = cfg.stateDir;
      };
      serviceConfig = {
        ExecStart = "${launch} ${lib.getExe cfg.package}";
        ExecStartPre = [ "${launch} ${if usePostgres then migrate else "${pkgs.coreutils}/bin/true"}" ] ++ lib.optional (cfg.environmentFile != null) "+${recordEnvironment}";
        DynamicUser = !managedPostgres;
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
      } // lib.optionalAttrs managedPostgres {
        User = "trek";
        Group = "trek";
      };
    };

    # These are for checking if the env file changed.
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
