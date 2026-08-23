{
  cmake,
  llvmPackages,
  openssl,
  libcap ? null,
  rustPlatform,
  pkg-config,
  lib,
  stdenv,
  fetchurl,
  version ? "0.0.0",
  ...
}:
let
  isAarch64Darwin = stdenv.hostPlatform.isAarch64 && stdenv.hostPlatform.isDarwin;

  # The v8 crate (rusty_v8) downloads its prebuilt static lib from GitHub at
  # build time. The nix sandbox blocks that download (no deno/python/curl in
  # PATH, no network), so we pre-fetch the archive and stage it in the cache
  # path the build script checks first (~/.cargo/.rusty_v8/<sanitized-url>).
  # See v8-150.4.0/build.rs::replace_non_alphanumeric and the early
  # `home::cargo_home().join(".rusty_v8")` cache lookup in the same file.
  rustyV8Archive = "librusty_v8_release_aarch64-apple-darwin.a.gz";
  rustyV8CacheKey = "https___github_com_denoland_rusty_v8_releases_download_v150_4_0_librusty_v8_release_aarch64_apple_darwin_a_gz";
  rustyV8Prebuilt = lib.optionalAttrs isAarch64Darwin {
    "${rustyV8CacheKey}" = fetchurl {
      url = "https://github.com/denoland/rusty_v8/releases/download/v150.4.0/${rustyV8Archive}";
      hash = "sha256-zNj4FIW4IsWxiuun+d65KaM4LYasZzu/DzZvBod+axA=";
    };
  };

in
rustPlatform.buildRustPackage (_: {
  env.PKG_CONFIG_PATH = lib.makeSearchPathOutput "dev" "lib/pkgconfig" (
    [ openssl ] ++ lib.optionals stdenv.isLinux [ libcap ]
  );
  pname = "codex-rs";
  inherit version;
  cargoLock.lockFile = ./Cargo.lock;
  doCheck = false;
  src = ./.;

  # Patch the workspace Cargo.toml so that cargo embeds the correct version in
  # CARGO_PKG_VERSION (which the binary reads via env!("CARGO_PKG_VERSION")).
  # On release commits the Cargo.toml already contains the real version and
  # this sed is a no-op.
  postPatch = ''
    sed -i 's/^version = "0\.0\.0"$/version = "${version}"/' Cargo.toml
  '';
  nativeBuildInputs = [
    cmake
    llvmPackages.clang
    llvmPackages.libclang.lib
    openssl
    pkg-config
  ] ++ lib.optionals stdenv.isLinux [
    libcap
  ];

  preBuild = lib.optionalString isAarch64Darwin ''
    # v8: stage the prebuilt static lib in the v8 build script's cache so it
    # skips the GitHub download. CARGO_HOME is rewritten to a writable path
    # inside the build sandbox; the build script reads it via home::cargo_home.
    export CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
    mkdir -p "$CARGO_HOME/.rusty_v8"
    cp ${rustyV8Prebuilt.${rustyV8CacheKey} or ""} \
       "$CARGO_HOME/.rusty_v8/${rustyV8CacheKey}"
  '';

  cargoLock.outputHashes = {
    "crossterm-0.29.0" = "sha256-cQxQQuV+YEutuQiPurXVISq6F/99vCEk8qe5PU8BCSo=";
    "nucleo-0.5.0" = "sha256-Hm4SxtTSBrcWpXrtSqeO0TACbUxq3gizg1zD/6Yw/sI=";
    "nucleo-matcher-0.3.1" = "sha256-Hm4SxtTSBrcWpXrtSqeO0TACbUxq3gizg1zD/6Yw/sI=";
    "runfiles-0.1.0" = "sha256-uJpVLcQh8wWZA3GPv9D8Nt43EOirajfDJ7eq/FB+tek=";
    "tokio-tungstenite-0.28.0" = "sha256-V1xmnrfRWOcZZogelZEA4vvyMj2awCfHVA5/glQ6KAI=";
    "tungstenite-0.27.0" = "sha256-VVHhk7l9J/sEmG3q/UuV/sQ3f+fGsmq5vumSy8vbMvw=";
  };

  meta = with lib; {
    description = "OpenAI Codex command‑line interface rust implementation";
    license = licenses.asl20;
    homepage = "https://github.com/openai/codex";
    mainProgram = "codex";
  };
})
