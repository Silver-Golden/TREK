# Nix

The flake packages the server, its shared contracts and the production web client for x86-64 Linux.

## Development
### Updating
It uses the repository's npm lockfile, after changing that lockfile update `npmDepsHash` in `nix/package.nix` using the hash reported by a build with ``npmDepsHash="";``.

### Testing
CI builds the package and boots the NixOS module in a VM, including a restart and persistence check.   
Run the same check on x86-64 Linux with KVM and flakes:

```sh
nix build --no-link -L .#checks.x86_64-linux.nixos
```

### CI/CD
A task has been added to [test.yml](../.github/workflows/test.yml), it runs the command found in [Testing](#testing).  
If the ``npmDepsHash`` has changed then it will fail, instructions on how to update are displayed in the output and in [Updating](#updating).  