# Nix

The flake packages the server, its shared contracts and the production web client for x86-64 and AArch64 Linux.

## Usage
### Nix

Build and run from a checkout with Nix flakes enabled:

```sh
nix build .#trek
nix run .#trek
```

The standalone command listens on port 3001.  
It keeps `data/` and `uploads/` under `$XDG_STATE_HOME/trek`, or `~/.local/state/trek` if XDG_STATE_HOME is unset.  
Set `TREK_STATE_DIR` to an absolute path to use another writable parent.  
See `server/.env.example` for the available environment variables.  
Production defaults require secure cookies, so deploy behind HTTPS, for local HTTP only, set `COOKIE_SECURE=false`.

### NixOS
For NixOS, add this repository as a flake input and import its module:

```nix
{
  inputs.trek.url = "github:liketrek/TREK";

  outputs = { nixpkgs, trek, ... }: {
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        trek.nixosModules.default
        {
          services.trek = {
            enable = true;
            settings = {
              APP_URL = "https://trek.example.org";
              ALLOWED_ORIGINS = "https://trek.example.org";
            };
            # Optional systemd EnvironmentFile, provisioned outside the store.
            environmentFile = "/run/secrets/trek.env";
          };
        }
      ];
    };
  };
}
```

The service listens on `127.0.0.1:3001` by default.  
Configure a reverse proxy for HTTPS.  
`services.trek.host` and `services.trek.port` change the listener.  
The service persists its database, encryption and session keys, plugins, backups and uploads under `/var/lib/trek`, back up that entire directory.  
The first-run administrator credentials are printed in the service logs.  
`settings` is stored in the world-readable Nix store, put passwords, API keys and other secrets in `environmentFile` instead.  
Do not set `TREK_STATE_DIR`, `NODE_ENV`, `HOST` or `PORT` in that file, as systemd environment files take precedence over the service settings.


Use a secrets manager such as [agenix](https://github.com/ryantm/agenix) or [sops-nix](https://github.com/Mic92/sops-nix) to provision the file and point `services.trek.environmentFile` at its runtime path.  
The file must exist before the service starts.  
It uses systemd's `EnvironmentFile=` syntax, not shell expansion.

The optional KItinerary booking extractor is not bundled.  
Install it separately and set `KITINERARY_EXTRACTOR_PATH` to its executable to enable that feature.

PostgreSQL 18 client tools are included for database backups and restores.  
Set `TREK_DB_PG_BIN_DIR` to use a different installation.

## Development
### Updating
The package uses the repository's npm lockfile.  
After changing that lockfile, update `npmDepsHash` in `nix/package.nix` using the hash reported by a build with `lib.fakeHash`.

### Testing
CI builds the package and boots the NixOS module in a VM, including a restart and persistence check.  
Run the same check on x86-64 Linux with KVM and flakes:

```sh
nix build --no-link -L .#checks.x86_64-linux.nixos
```

### CI/CD
The [test workflow](../.github/workflows/test.yml) runs the command in [Testing](#testing).  
It fails if `npmDepsHash` does not match the dependencies.
It restores a Nix store cache and saves it only on pushes to `dev` or `main`.  
The VM test runs again even when its previous result is cached.
