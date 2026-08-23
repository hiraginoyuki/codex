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

  # The v8_enable_sandbox feature has no upstream rusty_v8 prebuilt archive.
  # Codex publishes matching source-built archive/binding pairs for Cargo
  # package builds. These must match v8 150.4.0 and the target exactly.
  rustyV8ReleaseUrl = "https://github.com/openai/codex/releases/download/rusty-v8-v150.4.0";
  rustyV8Prebuilt = lib.optionalAttrs isAarch64Darwin {
    archive = fetchurl {
      url = "${rustyV8ReleaseUrl}/librusty_v8_ptrcomp_sandbox_release_aarch64-apple-darwin.a.gz";
      hash = "sha256-AK27SHmISMd1UEQcaGc6XoUpuOG3PqvN7iMss5tA9KE=";
    };
    binding = fetchurl {
      url = "${rustyV8ReleaseUrl}/src_binding_ptrcomp_sandbox_release_aarch64-apple-darwin.rs";
      hash = "sha256-ylrfDPicmnCtRgrnNkiy/om3SqETs8t/dXtqArdYOU8=";
    };
  };

in
rustPlatform.buildRustPackage (_: {
  env = {
    PKG_CONFIG_PATH = lib.makeSearchPathOutput "dev" "lib/pkgconfig" (
      [ openssl ] ++ lib.optionals stdenv.isLinux [ libcap ]
    );
  } // lib.optionalAttrs isAarch64Darwin {
    RUSTY_V8_ARCHIVE = rustyV8Prebuilt.archive;
    RUSTY_V8_SRC_BINDING_PATH = rustyV8Prebuilt.binding;
  };
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
