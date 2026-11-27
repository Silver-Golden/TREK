{
  testers,
  lib,
  pkgs,
  nodejs_24,
  postgresql_18,
  trekModule,
  trekPackage,
}:
let
  evaluateWith = options: extra: (import "${pkgs.path}/nixos/lib/eval-config.nix" {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      trekModule
      { system.stateVersion = "26.05"; services.trek = { enable = true; } // options; }
      extra
    ];
  }).config;
  evaluate = options: evaluateWith options { };
  postgresVersionAllowed = version:
    let
      c = evaluateWith { } {
        services.postgresql.package = postgresql_18.overrideAttrs (_: { inherit version; __intentionallyOverridingVersion = true; });
      };
    in builtins.all (a: a.assertion || a.message != "services.trek.database = postgresql requires PostgreSQL 14 through 18.") c.assertions;
  validStateDir = path:
    let c = evaluate { stateDir = path; };
    in builtins.all (a: a.assertion || !(lib.hasPrefix "services.trek.stateDir " a.message)) c.assertions;
  defaultConfig = evaluate { };
  hostConfig = evaluateWith { database = "sqlite"; } { services.postgresql.enable = true; };
in
assert defaultConfig.services.trek.stateDir == "/var/lib/trek";
assert defaultConfig.services.trek.database == "postgresql";
assert defaultConfig.services.postgresql.package == hostConfig.services.postgresql.package;
assert builtins.all postgresVersionAllowed [ "14.0" "15.0" "16.0" "17.0" "18.0" ];
assert builtins.all (v: !postgresVersionAllowed v) [ "13.9" "19.0" ];
assert (evaluate { database = "external-postgresql"; }).systemd.services.trek.serviceConfig.DynamicUser;
assert (evaluate { database = "sqlite"; }).systemd.services.trek.serviceConfig.DynamicUser;
assert builtins.elem "postgresql-setup.service" defaultConfig.systemd.services.trek.requires;
assert defaultConfig.systemd.services.trek.serviceConfig.User == "trek";
assert defaultConfig.systemd.services.trek.serviceConfig.StateDirectory == "trek";
assert defaultConfig.systemd.services.trek.serviceConfig.WorkingDirectory == "/var/lib/trek";
assert !(builtins.hasAttr "trek-environment" defaultConfig.systemd.timers);
assert !(builtins.hasAttr "trek-environment" defaultConfig.systemd.services);
assert builtins.all validStateDir [ "/var/lib/trek" "/var/lib/travel/trek" "/var/lib/trek-v2/test_1" ];
assert builtins.all (path: !validStateDir path) [ "" "/var/lib" "/tmp/trek" "/var/lib/../trek" "/var/lib/./trek" "/var/lib/trek/" "/var/lib//trek" "/var/lib/private" "/var/lib/private/trek" "/var/lib/trek:other" "/var/lib/trek%h" "/var/lib/trek data" ];
testers.runNixOSTest {
  name = "trek-service";

  nodes.machine = { pkgs, ... }: {
    imports = [ trekModule ];
    system.stateVersion = "26.05";
    environment.systemPackages = [ pkgs.curl pkgs.sqlite postgresql_18 ];
    services.postgresql = {
      enableTCPIP = true;
      settings = {
        port = 5544;
        unix_socket_directories = "/run/trek-postgres";
      };
      authentication = "host trek trek 192.168.1.0/24 scram-sha-256";
    };
    networking.firewall.allowedTCPPorts = [ 5544 ];
    systemd.services.postgresql.serviceConfig.ReadWritePaths = [ "/run/trek-postgres" ];
    systemd.services.trek.wantedBy = lib.mkForce [ ];
    systemd.services.sqlite-seed = {
      environment = {
        NODE_ENV = "production";
        HOST = "127.0.0.1";
        PORT = "3202";
        TREK_STATE_DIR = "/var/lib/travel/trek";
        TREK_DB_FILE = "/var/lib/travel/trek/data/custom.db";
        TREK_SERVICES = "off";
        COOKIE_SECURE = "false";
        ADMIN_EMAIL = "admin@example.test";
        ADMIN_PASSWORD = "testing-only-password";
      };
      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "travel/trek";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/travel/trek";
        ExecStart = "${trekPackage}/bin/trek";
      };
    };
    systemd.services.old-state.serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      StateDirectory = "travel/trek";
      StateDirectoryMode = "0700";
      WorkingDirectory = "/var/lib/travel/trek";
      ExecStart = pkgs.writeShellScript "trek-old-state" ''
        set -eu
        if [ -d /var/lib/travel/trek/data ]; then
          test -r /var/lib/travel/trek/data/.jwt_secret
          test -r /var/lib/travel/trek/data/.encryption_key
        fi
        printf 'existing state\n' > /var/lib/travel/trek/existing-state
      '';
    };
    systemd.tmpfiles.rules = [
      "d /run/trek-test-secrets 0700 root root -"
      "d /run/trek-postgres 0775 postgres postgres -"
      "d /run/trek-test-secrets/first 0700 root root -"
      "C /run/trek-test-secrets/first/trek.env 0600 root root - ${pkgs.writeText "trek-test.env" ''
        COOKIE_SECURE=false
        ADMIN_EMAIL=admin@example.test
        ADMIN_PASSWORD=testing-only-password
        TREK_TEST_VALUE=initial
        TREK_DB_FILE=/var/lib/travel/trek/data/custom.db
      ''}"
      "L /run/trek-test-secrets/current - - - - /run/trek-test-secrets/first"
    ];
    services.trek = {
      enable = true;
      package = trekPackage;
      port = 3201;
      stateDir = "/var/lib/travel/trek";
      environmentFile = "/run/trek-test-secrets/current/trek.env";
      settings.TREK_SERVICES = "off";
    };
  };

  nodes.external = { pkgs, ... }: {
    imports = [ trekModule ];
    system.stateVersion = "26.05";
    environment.systemPackages = [ pkgs.curl ];
    systemd.services.trek.wantedBy = lib.mkForce [ ];
    systemd.services.trek.serviceConfig.Restart = lib.mkForce "no";
    services.trek = {
      enable = true;
      database = "external-postgresql";
      package = trekPackage;
      port = 3201;
      environmentFile = "/run/trek-external.env";
      settings = { TREK_SERVICES = "off"; COOKIE_SECURE = "false"; };
    };
  };

  nodes.sqlite = { pkgs, ... }: {
    imports = [ trekModule ];
    system.stateVersion = "26.05";
    environment.systemPackages = [ pkgs.curl ];
    services.trek = {
      enable = true;
      database = "sqlite";
      package = trekPackage;
      port = 3201;
      settings = { TREK_SERVICES = "off"; COOKIE_SECURE = "false"; };
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("trek-environment.timer")
    machine.succeed("systemctl start old-state.service")
    machine.succeed("systemctl start sqlite-seed.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3202/api/health/ready | grep -q '\"ready\"'", timeout=180)
    machine.succeed("systemctl stop sqlite-seed.service")
    machine.succeed("printf '\\nRESTORE_FROM_BACKUP=/tmp/backup.tar\\n' >> /run/trek-test-secrets/current/trek.env")
    machine.fail("systemctl start trek.service")
    machine.succeed("journalctl -u trek.service --no-pager | grep -F 'SQLite data and RESTORE_FROM_BACKUP are both present'")
    machine.succeed("sed -i '/^RESTORE_FROM_BACKUP=/d' /run/trek-test-secrets/current/trek.env; systemctl reset-failed trek.service")
    machine.succeed("systemctl start trek.service")
    machine.succeed("systemctl cat trek-environment.timer | grep -Fx 'OnBootSec=1min' && systemctl cat trek-environment.timer | grep -Fx 'OnUnitInactiveSec=1min'")
    machine.wait_for_unit("trek.service")
    machine.wait_for_open_port(3201)
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3201/api/health/ready | grep -q '\"ready\"'", timeout=180)
    machine.succeed("curl -fsS http://127.0.0.1:3201/ | grep -q '<div id=\"root\">'")
    machine.succeed("systemctl show trek.service -p DynamicUser --value | grep -qx no")
    machine.succeed("systemctl show trek.service -p User --value | grep -qx trek")
    machine.succeed("systemctl show trek.service -p WorkingDirectory --value | grep -Fx /var/lib/travel/trek")
    machine.succeed("test \"$(stat -Lc '%d:%i' /proc/$(systemctl show trek.service -p MainPID --value)/cwd)\" = \"$(stat -Lc '%d:%i' /var/lib/travel/trek)\"")
    machine.succeed("grep -zqx 'TREK_STATE_DIR=/var/lib/travel/trek' /proc/$(systemctl show trek.service -p MainPID --value)/environ")
    machine.succeed("grep -zqx 'TREK_DB_PG_BIN_DIR=${postgresql_18}/bin' /proc/$(systemctl show trek.service -p MainPID --value)/environ")
    machine.succeed("${postgresql_18}/bin/pg_dump --version && ${postgresql_18}/bin/pg_restore --version && ${postgresql_18}/bin/psql --version")
    machine.succeed("cd ${trekPackage}/lib/trek/server && ! env TREK_STATE_DIR=relative ${nodejs_24}/bin/node --import tsx scripts/migrate-encryption.ts > /tmp/trek-migration-test.log 2>&1 && grep -q 'TREK_STATE_DIR must be an absolute path' /tmp/trek-migration-test.log")
    machine.succeed("test -s /var/lib/travel/trek/data/custom.db && test -d /var/lib/travel/trek/uploads")
    machine.succeed("grep -qx 'existing state' /var/lib/travel/trek/existing-state")
    machine.succeed("runuser -u trek -- psql -h /run/trek-postgres -p 5544 -d trek -tAc \"SELECT email FROM users WHERE email = 'admin@example.test'\" | grep -qx admin@example.test")
    machine.succeed("runuser -u postgres -- psql -h /run/trek-postgres -p 5544 -tAc \"select not rolsuper and not rolcreatedb and not rolcreaterole from pg_roles where rolname = 'trek'\" | grep -qx t")
    keys = machine.succeed("sha256sum /var/lib/travel/trek/data/.jwt_secret /var/lib/travel/trek/data/.encryption_key")
    def wait_for_restart(pid, value):
        machine.wait_until_succeeds(f"test $(systemctl show trek.service -p MainPID --value) -gt 0 && test $(systemctl show trek.service -p MainPID --value) != {pid}", timeout=180)
        machine.wait_for_unit("trek.service")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3201/api/health/ready | grep -q '\"ready\"'", timeout=180)
        machine.succeed(f"tr '\\0' '\\n' < /proc/$(systemctl show trek.service -p MainPID --value)/environ | grep -qx TREK_TEST_VALUE={value}")
        return machine.succeed("systemctl show trek.service -p MainPID --value").strip()

    pid = machine.succeed("systemctl show trek.service -p MainPID --value").strip()
    machine.succeed("printf '\\nTREK_TEST_VALUE=written\\n' >> /run/trek-test-secrets/current/trek.env")
    pid = wait_for_restart(pid, "written")
    machine.succeed("sed -i 's/TREK_TEST_VALUE=written/TREK_TEST_VALUE=replaced/' /run/trek-test-secrets/current/trek.env")
    pid = wait_for_restart(pid, "replaced")
    machine.succeed("mkdir /run/trek-test-secrets/second; sed 's/TREK_TEST_VALUE=replaced/TREK_TEST_VALUE=rotated/' /run/trek-test-secrets/current/trek.env > /run/trek-test-secrets/second/trek.env; ln -s /run/trek-test-secrets/second /run/trek-test-secrets/next; mv -Tf /run/trek-test-secrets/next /run/trek-test-secrets/current")
    pid = wait_for_restart(pid, "rotated")
    machine.succeed("cp /run/trek-test-secrets/current/trek.env /run/trek-test-secrets/current/new.env; mv -f /run/trek-test-secrets/current/new.env /run/trek-test-secrets/current/trek.env")
    pid = wait_for_restart(pid, "rotated")
    machine.succeed("mv /run/trek-test-secrets/current/trek.env /run/trek-test-secrets/current/held.env")
    machine.fail("systemctl start trek-environment.service")
    machine.succeed(f"test $(systemctl show trek.service -p MainPID --value) = {pid}")
    machine.succeed("mv /run/trek-test-secrets/current/held.env /run/trek-test-secrets/current/trek.env")
    wait_for_restart(pid, "rotated")
    assert machine.succeed("sha256sum /var/lib/travel/trek/data/.jwt_secret /var/lib/travel/trek/data/.encryption_key") == keys
    machine.succeed("runuser -u trek -- psql -h /run/trek-postgres -p 5544 -d trek -tAc \"SELECT email FROM users WHERE email = 'admin@example.test'\" | grep -qx admin@example.test")
    machine.succeed("systemctl stop trek.service")
    machine.succeed("systemctl start old-state.service")
    machine.succeed("systemctl start trek.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3201/api/health/ready | grep -q '\"ready\"'", timeout=180)
    assert machine.succeed("sha256sum /var/lib/travel/trek/data/.jwt_secret /var/lib/travel/trek/data/.encryption_key") == keys
    machine.succeed("systemctl stop trek.service")
    invocation = machine.succeed("systemctl show trek-environment.service -p InvocationID --value").strip()
    machine.succeed("printf '\\nTREK_TEST_VALUE=stopped\\n' >> /run/trek-test-secrets/current/trek.env")
    machine.wait_until_succeeds(f"test $(systemctl show trek-environment.service -p InvocationID --value) != {invocation}", timeout=120)
    machine.succeed("test $(systemctl show trek.service -p MainPID --value) = 0 && ! systemctl is-active --quiet trek.service")
    machine.succeed("printf '\\nTREK_DB_URL=postgresql://unexpected/trek\\n' >> /run/trek-test-secrets/current/trek.env")
    machine.fail("systemctl start trek.service")
    machine.succeed("journalctl -u trek.service --no-pager | grep -F 'conflicts with TREK_DB_URL'")
    machine.succeed("runuser -u postgres -- psql -h /run/trek-postgres -p 5544 -c \"ALTER ROLE trek PASSWORD 'external-test-password'\"")
    external.start()
    external.succeed("printf 'TREK_DB_URL=  \\n' > /run/trek-external.env")
    external.fail("systemctl start trek.service")
    external.succeed("journalctl -u trek.service --no-pager | grep -F 'TREK_DB_URL is required'")
    external.succeed("systemctl reset-failed trek.service")
    machine_ip = machine.succeed("ip -4 -o addr show dev eth1 | awk '{split($4,a,\"/\"); print a[1]}'").strip()
    external.succeed(f"printf '%s\\n' 'TREK_DB_URL=postgresql://trek:external-test-password@{machine_ip}:5544/trek?sslmode=disable' > /run/trek-external.env; chmod 600 /run/trek-external.env")
    external.succeed("systemctl start trek.service")
    external.wait_until_succeeds("curl -fsS http://127.0.0.1:3201/api/health/ready | grep -q '\"ready\"'", timeout=180)
    external.succeed("systemctl show trek.service -p DynamicUser --value | grep -qx yes")
    external.succeed("test ! -e /var/lib/trek/data/travel.db")
    external.succeed("systemctl stop trek.service")
    machine.succeed("sed -i '/^TREK_DB_URL=/d' /run/trek-test-secrets/current/trek.env")
    machine.succeed("sqlite3 /var/lib/travel/trek/data/custom.db \"update users set display_name = 'Changed after migration' where email = 'admin@example.test'\"")
    machine.succeed("systemctl reset-failed trek.service")
    machine.succeed("sqlite3 /var/lib/travel/trek/data/custom.db 'delete from mikro_orm_migrations'")
    machine.succeed("systemctl start trek.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3201/api/health/ready | grep -q '\"ready\"'", timeout=180)
    machine.succeed("journalctl -u trek.service --no-pager | grep -F 'PostgreSQL target is not empty; skipping the SQLite move.'")
    machine.succeed("runuser -u trek -- psql -h /run/trek-postgres -p 5544 -d trek -tAc \"SELECT email FROM users WHERE email = 'admin@example.test'\" | grep -qx admin@example.test")
    sqlite.start()
    sqlite.wait_until_succeeds("curl -fsS http://127.0.0.1:3201/api/health/ready | grep -q '\"ready\"'", timeout=180)
    sqlite.succeed("systemctl show trek.service -p DynamicUser --value | grep -qx yes")
    sqlite.succeed("test -s /var/lib/private/trek/data/travel.db")
    sqlite.succeed("! systemctl is-active --quiet postgresql.service")
  '';
}
