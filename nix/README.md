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
See the [NixOS installation guide](../wiki/Install-NixOS.md) for service configuration, secrets, backups and updates.

The NixOS service provisions PostgreSQL by default and migrates an existing SQLite installation on first startup.  
Set `services.trek.database` to `"external-postgresql"` or `"sqlite"` to choose another backend.

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
The VM test result is reused when it is already available in the Nix store.
