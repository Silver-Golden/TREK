# Install: NixOS

Install TREK as a NixOS systemd service.  
The package includes the server and web client.  
Docker is not required.

## Prerequisites

- An x86-64 or AArch64 NixOS system with flakes enabled and access to GitHub and the npm registry
- A flake-based NixOS configuration and permission to rebuild it
- An HTTPS reverse proxy and a domain for a production installation

## Install

Add TREK as an input to your existing NixOS flake, then import its module into your host configuration.  
For example, adapt the following to your existing inputs and hostname:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.trek.url = "github:liketrek/TREK";

  outputs = { nixpkgs, trek, ... }: {
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        trek.nixosModules.default
        {
          services.trek = {
            enable = true;
            settings = {
              APP_URL = "https://trek.example.org";
              ALLOWED_ORIGINS = "https://trek.example.org";
            };
          };
        }
      ];
    };
  };
}
```

Replace `example` with your NixOS configuration name and the example domain with your own.  
Use `aarch64-linux` instead of `x86_64-linux` for an AArch64 system.  
The module builds TREK using your NixOS configuration's `nixpkgs`.  
The initial build downloads npm dependencies and may take some time.

Apply the configuration from your flake directory:

```bash
sudo nixos-rebuild switch --flake .#example
```

TREK listens on `127.0.0.1:3001` by default.  
Configure your reverse proxy to forward requests, including WebSocket traffic, to that address and serve the public URL over HTTPS.  
See [Reverse-Proxy](Reverse-Proxy).

## First Start and Logs
Check the service and its readiness endpoint on the NixOS host:

```bash
systemctl status trek.service
curl -fsS http://127.0.0.1:3001/api/health/ready
sudo journalctl -u trek.service -b
```

On the first start, TREK creates an administrator.  
If `ADMIN_EMAIL` and `ADMIN_PASSWORD` are both set before the first start, they are used for that account.  
Otherwise a generated password is printed in the service logs.  
These variables only apply when the user database is empty.

## Configuration and Secrets
Use `services.trek.host` and `services.trek.port` to change the listener.  
Put non-secret environment variables in `services.trek.settings`.  
Their values are visible in the Nix store.  
For passwords and other secrets, use a secret manager such as [agenix](https://github.com/ryantm/agenix) or [sops-nix](https://github.com/Mic92/sops-nix) to provision a systemd environment file at runtime.  
Configure TREK to use the secret manager's decrypted file path:

```nix
services.trek.environmentFile = "/run/secrets/trek-env";
```

The path above is an example.  
Use the path configured by your secret manager.  
Ensure it provisions the file before TREK starts and restricts access to it.  
The decrypted file must use systemd `EnvironmentFile=` syntax, not shell expansion.  
To choose the initial administrator, include both `ADMIN_EMAIL` and `ADMIN_PASSWORD` in the secret.

Environment-file values take precedence over `settings`.  
Do not set `TREK_STATE_DIR`, `NODE_ENV`, `HOST` or `PORT` there, as the module manages them.  
TREK checks the environment file approximately once a minute and restarts if the file or its contents change.  
A manually stopped service remains stopped.  
If the file cannot be read, the check logs an error and retries.

See [Environment-Variables](Environment-Variables) for the available settings.  
The optional KItinerary booking extractor is not bundled.  
Install it separately and set `KITINERARY_EXTRACTOR_PATH` to its executable to enable it.

## PostgreSQL
By default, the module enables the local NixOS PostgreSQL service and provisions a `trek` database and a non-superuser `trek` role.  
TREK connects through a Unix socket using peer authentication and waits for database provisioning before starting.  
The managed server must be PostgreSQL 14 through 18.  
The module preserves the host's `services.postgresql.package` setting, including the default chosen by NixOS from `system.stateVersion`.  
To select PostgreSQL 18, set `services.postgresql.package = pkgs.postgresql_18;`.

This package setting affects the host's entire PostgreSQL service, not just TREK.  
Upgrade PostgreSQL using its documented migration procedure when changing major versions.  
If a database or role named `trek` already exists, NixOS reuses it, changes the database owner to `trek`, and updates the role's login and privilege attributes.  
Check for name collisions before enabling the module.

The module uses the first entry in `services.postgresql.settings.unix_socket_directories`, or `/run/postgresql` when unset.  
The selected directory must be an absolute path using ASCII letters, digits, dots, underscores, slashes or hyphens, and must be writable by PostgreSQL and accessible to TREK.  
The configured PostgreSQL port is used automatically.  
Host PostgreSQL authentication must permit peer access for the `trek` user.

To connect to an existing PostgreSQL server instead, set `services.trek.database = "external-postgresql";` and provide `TREK_DB_URL` through `services.trek.environmentFile`.  
The service refuses to start without a nonempty URL and does not fall back to SQLite.  
Do not set `TREK_DB_URL` when local management is enabled.  
The external server must run PostgreSQL 14 through 18.  
Its version cannot be checked by a Nix evaluation assertion, and TREK checks it during normal database startup.  
See [Database-Postgres](Database-Postgres) for connection security, backups and PostgreSQL requirements.

To retain SQLite, set `services.trek.database = "sqlite";`.  
When switching to PostgreSQL, TREK automatically migrates an existing SQLite database into an empty PostgreSQL database without deleting the SQLite source.  
An existing `TREK_DB_FILE` selects the SQLite source; SQLite journal and synchronous settings do not apply to PostgreSQL.  
Back up state and secrets independently before switching.  
Stop any other process that writes to the SQLite, plugin or PostgreSQL databases before switching, and keep it stopped during migration.  
Update an outdated SQLite database on SQLite first, and do not configure `RESTORE_FROM_BACKUP` at the same time as an existing SQLite database.  
If the target is not empty, the service skips the move and starts on PostgreSQL, even when it contains unrelated data or an interrupted migration.  
Check the target before switching; an existing SQLite source does not prove that its data reached PostgreSQL.  
The existing move command removes the schema it created on an ordinary failure, and a failure after an ambiguous commit can remove a completed copy.  
Changes to SQLite after switching are not automatically copied to PostgreSQL.

## Backups and Updates
TREK stores its database, encryption and session keys, plugins, backups and uploads under `/var/lib/trek` by default.  
Set `services.trek.stateDir` to another normalized directory beneath `/var/lib` to change both the state and working directory.  
The directory must be outside `/var/lib/private`, and its components may contain ASCII letters, digits, dots, underscores and hyphens.  
Back up the entire configured directory.  
Also back up any environment file and secrets separately and securely.  
See [Backups](Backups).

To update TREK, update the flake input in your NixOS configuration, review the lockfile change, and rebuild:

```bash
nix flake update trek
sudo nixos-rebuild switch --flake .#example
```

Adjust the path and configuration name to match your system.  
Back up before upgrading.  
Database migrations can prevent an older version from using a newer database.  
See [Updating](Updating#database-migrations).

## Next Steps
- [Environment Variables](Environment-Variables) - complete variable reference
- [Reverse Proxy](Reverse-Proxy) - HTTPS configuration
- [Backups](Backups) - backup and restore options
