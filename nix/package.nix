{
  lib,
  buildNpmPackage,
  nodejs_24,
  postgresql_18,
  autoPatchelfHook,
  stdenv,
  zlib,
  makeWrapper,
}:

buildNpmPackage {
  pname = "trek";
  version = (builtins.fromJSON (builtins.readFile ../package.json)).version;
  src =
    let
      root = toString ../.;
      excluded = map (path: "${root}/${path}") [
        "server/data"
        "server/uploads"
        "server/dist"
        "server/public"
        "shared/dist"
        "client/dist"
      ];
    in
    lib.cleanSourceWith {
      src = ../.;
      filter =
        path: type:
        let
          name = baseNameOf path;
        in
        !(builtins.elem (toString path) excluded)
        && name != "node_modules"
        && !(name == ".env" || (lib.hasPrefix ".env." name && name != ".env.example"))
        && lib.cleanSourceFilter path type;
    };
  nodejs = nodejs_24;

  npmDepsFetcherVersion = 2;
  npmDepsHash = "sha256-REtwWCab7bvRCrVfO6CRz3zaEpArkANkIAZvKgTbrl0=";
  npmRebuildFlags = [ "--ignore-scripts" ];
  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];
  buildInputs = [ stdenv.cc.cc.lib zlib ];
  # npm packages also contain musl builds, which a glibc Node never loads.
  autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" "libc.musl-aarch64.so.1" ];

  buildPhase = ''
    runHook preBuild
    for workspace in shared server client; do
      if [ -d "$workspace/node_modules" ]; then
        patchShebangs "$workspace/node_modules"
      fi
    done
    export NODE_OPTIONS=--max-old-space-size=4096
    export LD_LIBRARY_PATH=${lib.makeLibraryPath [ stdenv.cc.cc.lib zlib ]}
    npm run build
    npm ci --workspace=server --omit=dev --ignore-scripts
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/trek/server" "$out/lib/trek/shared" "$out/bin"
    cp -r node_modules "$out/lib/trek/"
    cp -r server/dist server/assets server/tsconfig.json server/package.json server/reset-admin.js "$out/lib/trek/server/"
    if [ -d server/node_modules ]; then cp -r server/node_modules "$out/lib/trek/server/"; fi
    mkdir -p "$out/lib/trek/server/scripts"
    cp server/scripts/migrate-encryption.ts server/scripts/migrate-encryption-stores.ts "$out/lib/trek/server/scripts/"
    cp -r shared/dist shared/package.json "$out/lib/trek/shared/"
    if [ -d shared/node_modules ]; then cp -r shared/node_modules "$out/lib/trek/shared/"; fi
    cp -r client/dist "$out/lib/trek/server/public"
    mkdir -p "$out/lib/trek/server/public/fonts"
    cp -r client/public/fonts/. "$out/lib/trek/server/public/fonts/"
    cp -r wiki "$out/lib/trek/"
    makeWrapper ${nodejs_24}/bin/node "$out/bin/trek" \
      --set-default NODE_ENV production \
      --set-default TREK_DB_PG_BIN_DIR "${postgresql_18}/bin" \
      --set-default TS_NODE_PROJECT "$out/lib/trek/server/tsconfig.json" \
      --set-default DOTENV_CONFIG_PATH "$out/lib/trek/server/.env" \
      --run 'if [ -z "''${TREK_STATE_DIR:-}" ]; then if [ -n "''${XDG_STATE_HOME:-}" ]; then export TREK_STATE_DIR="$XDG_STATE_HOME/trek"; elif [ -n "''${HOME:-}" ]; then export TREK_STATE_DIR="$HOME/.local/state/trek"; else echo "Set TREK_STATE_DIR to a writable absolute directory" >&2; exit 1; fi; fi' \
      --add-flags "--require $out/lib/trek/node_modules/tsconfig-paths/register" \
      --add-flags "$out/lib/trek/server/dist/index.js"
    runHook postInstall
  '';

  meta = {
    description = "Self-hosted collaborative travel planner";
    homepage = "https://github.com/liketrek/TREK";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "trek";
  };
}
