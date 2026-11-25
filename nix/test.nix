{
  testers,
  nodejs_24,
  postgresql_18,
  trekModule,
  trekPackage,
}:

testers.runNixOSTest {
  name = "trek-service";

  nodes.machine = { pkgs, ... }: {
    imports = [ trekModule ];
    environment.systemPackages = [ pkgs.curl pkgs.sqlite ];
    environment.etc."trek-test.env".text = ''
      COOKIE_SECURE=false
      ADMIN_EMAIL=admin@example.test
      ADMIN_PASSWORD=testing-only-password
    '';
    services.trek = {
      enable = true;
      package = trekPackage;
      port = 3201;
      environmentFile = "/etc/trek-test.env";
      settings.TREK_SERVICES = "off";
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("trek.service")
    machine.wait_for_open_port(3201)
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3201/api/health/ready | grep -q '\"ready\"'", timeout=180)
    machine.succeed("curl -fsS http://127.0.0.1:3201/ | grep -q '<div id=\"root\">'")
    machine.succeed("systemctl show trek.service -p DynamicUser --value | grep -qx yes")
    machine.succeed("grep -zqx 'TREK_DB_PG_BIN_DIR=${postgresql_18}/bin' /proc/$(systemctl show trek.service -p MainPID --value)/environ")
    machine.succeed("${postgresql_18}/bin/pg_dump --version && ${postgresql_18}/bin/pg_restore --version && ${postgresql_18}/bin/psql --version")
    machine.succeed("cd ${trekPackage}/lib/trek/server && ! env TREK_STATE_DIR=relative ${nodejs_24}/bin/node --import tsx scripts/migrate-encryption.ts > /tmp/trek-migration-test.log 2>&1 && grep -q 'TREK_STATE_DIR must be an absolute path' /tmp/trek-migration-test.log")
    machine.succeed("test -s /var/lib/trek/data/travel.db && test -d /var/lib/trek/uploads")
    machine.succeed("sqlite3 /var/lib/trek/data/travel.db \"SELECT email FROM users WHERE email = 'admin@example.test'\" | grep -qx admin@example.test")
    keys = machine.succeed("sha256sum /var/lib/trek/data/.jwt_secret /var/lib/trek/data/.encryption_key")
    machine.succeed("systemctl restart trek.service")
    machine.wait_for_unit("trek.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3201/api/health/ready | grep -q '\"ready\"'", timeout=180)
    assert machine.succeed("sha256sum /var/lib/trek/data/.jwt_secret /var/lib/trek/data/.encryption_key") == keys
    machine.succeed("sqlite3 /var/lib/trek/data/travel.db \"SELECT email FROM users WHERE email = 'admin@example.test'\" | grep -qx admin@example.test")
  '';
}
