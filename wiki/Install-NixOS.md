# Install: NixOS

Install TREK as a NixOS systemd service.   
The package includes the server and web client, Docker is not required.

## Prerequisites

- An x86-64 NixOS system with flakes enabled and access to GitHub and the npm registry
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
If `ADMIN_EMAIL` and `ADMIN_PASSWORD` are both set before the first start, they are used for that account, otherwise a generated password is printed in the service logs.   
These variables only apply when the user database is empty.

## Configuration and Secrets
Use `services.trek.host` and `services.trek.port` to change the listener.   
Put non-secret environment variables in `services.trek.settings`, their values are visible in the Nix store.   
For passwords and other secrets, use a secret manager such as [agenix](https://github.com/ryantm/agenix) or [sops-nix](https://github.com/Mic92/sops-nix) to provision a systemd environment file at runtime.    
Configure TREK to use the secret manager's decrypted file path:

```nix
services.trek.environmentFile = "/run/secrets/trek-env";
```

The path above is an example, use the path configured by your secret manager.   
Ensure it provisions the file before TREK starts and restricts access to it.   
The decrypted file must use systemd `EnvironmentFile=` syntax, not shell expansion.   
To choose the initial administrator, include both `ADMIN_EMAIL` and `ADMIN_PASSWORD` in the secret.

Environment-file values take precedence over `settings`, so do not set `TREK_STATE_DIR`, `NODE_ENV`, `HOST` or `PORT` there, the module manages them.  
TREK checks the environment file approximately once a minute and restarts if the file or its contents change.  
A manually stopped service remains stopped.  
If the file cannot be read, the check logs an error and retries.

See [Environment-Variables](Environment-Variables) for the available settings.   
The optional KItinerary booking extractor is not bundled, install it separately and set `KITINERARY_EXTRACTOR_PATH` to its executable to enable it.


## Backups and Updates
TREK stores its database, encryption and session keys, plugins, backups and uploads under `/var/lib/trek` by default.  
Set `services.trek.stateDir` to another absolute directory beneath `/var/lib` to change both the state and working directory.  
Back up the entire configured directory.  
Also back up any environment file and secrets separately and securely.  
See [Backups](Backups).

To update TREK, update the flake input in your NixOS configuration, review the lockfile change, and rebuild:

```bash
nix flake update trek
sudo nixos-rebuild switch --flake .#example
```

Adjust the path and configuration name to match your system.   
Back up before upgrading, database migrations can prevent an older version from using a newer database.   
See [Updating](Updating#database-migrations).

## Next Steps
- [Environment Variables](Environment-Variables) - complete variable reference
- [Reverse Proxy](Reverse-Proxy) - HTTPS configuration
- [Backups](Backups) - backup and restore options
