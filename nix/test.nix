{
  testers,
  trekModule,
  trekPackage,
}:

testers.runNixOSTest {
  name = "trek-service";

  nodes.machine = { pkgs, ... }: {
    imports = [ trekModule ];
    environment.systemPackages = [ pkgs.curl pkgs.sqlite ];
    systemd.tmpfiles.rules = [
      "d /run/trek-test-secrets 0700 root root -"
      "d /run/trek-test-secrets/first 0700 root root -"
      "C /run/trek-test-secrets/first/trek.env 0600 root root - ${pkgs.writeText "trek-test.env" ''
        COOKIE_SECURE=false
        ADMIN_EMAIL=admin@example.test
        ADMIN_PASSWORD=testing-only-password
        TREK_TEST_VALUE=initial
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

  testScript = ''
    machine.start()
    machine.wait_for_unit("trek-environment.timer")
    machine.succeed("systemctl cat trek-environment.timer | grep -Fx 'OnBootSec=1min' && systemctl cat trek-environment.timer | grep -Fx 'OnUnitInactiveSec=1min'")
    machine.wait_for_unit("trek.service")
    machine.wait_for_open_port(3201)
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:3201/api/health/ready | grep -q '\"ready\"'", timeout=180)
    machine.succeed("curl -fsS http://127.0.0.1:3201/ | grep -q '<div id=\"root\">'")
    machine.succeed("systemctl show trek.service -p DynamicUser --value | grep -qx yes")
    machine.succeed("test -s /var/lib/travel/trek/data/travel.db && test -d /var/lib/travel/trek/uploads")
    machine.succeed("sqlite3 /var/lib/travel/trek/data/travel.db \"SELECT email FROM users WHERE email = 'admin@example.test'\" | grep -qx admin@example.test")
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
    wait_for_restart(pid, "rotated")
    assert machine.succeed("sha256sum /var/lib/travel/trek/data/.jwt_secret /var/lib/travel/trek/data/.encryption_key") == keys
    machine.succeed("sqlite3 /var/lib/travel/trek/data/travel.db \"SELECT email FROM users WHERE email = 'admin@example.test'\" | grep -qx admin@example.test")
    machine.succeed("systemctl stop trek.service")
    invocation = machine.succeed("systemctl show trek-environment.service -p InvocationID --value").strip()
    machine.succeed("printf '\\nTREK_TEST_VALUE=stopped\\n' >> /run/trek-test-secrets/current/trek.env")
    machine.wait_until_succeeds(f"test $(systemctl show trek-environment.service -p InvocationID --value) != {invocation}", timeout=120)
    machine.succeed("test $(systemctl show trek.service -p MainPID --value) = 0 && ! systemctl is-active --quiet trek.service")
  '';
}
