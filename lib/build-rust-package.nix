# buildWindowsRustPackage — cross-compile a Rust crate from Linux to
# x86_64-pc-windows-gnu using `pkgsCross.mingwW64` + `rustPlatform`.
#
# Wraps nixpkgs' cross-compilation path with the env-var plumbing that
# `rustPlatform.buildRustPackage` expects but doesn't default:
#   - CARGO_BUILD_TARGET (distinct from the Nix cross triple)
#   - CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER (MinGW gcc wrapper)
#   - WINDRES (for the `embed-resource` crate and similar RC-file consumers)
#   - HOST_CC (so build-scripts that need a host cc don't leak target cc)
#   - depsBuildBuild additions (build-scripts + proc-macros run on the build host)
#   - windows.pthreads in buildInputs (required by most C-touching crates)
#
# Tests are disabled by default (`doCheck = false`): we can't execute
# Windows binaries on the Linux build host without Wine, and the default
# cargo test runner would otherwise try and fail.
#
# Usage:
#   let buildRust = lib.buildWindowsRustPackage pkgs; in
#   buildRust {
#     pname = "foo"; version = "0.1.0";
#     src = ./.; cargoHash = "sha256-...";
#   }
#
# The returned derivation produces PE32+ executables under `$out/bin/`.
# Pass the whole output directory to `win.packages.<name>.package` to ship it.

{ pkgs }:

let
  lib = pkgs.lib;
  crossPkgs = pkgs.pkgsCross.mingwW64;
  targetPrefix = crossPkgs.stdenv.cc.targetPrefix;
in

args:
let
  userArgs = args // { };

  userDepsBuildBuild = userArgs.depsBuildBuild or [ ];
  userNativeBuildInputs = userArgs.nativeBuildInputs or [ ];
  userBuildInputs = userArgs.buildInputs or [ ];
  userEnv = userArgs.env or { };

  # Nix cross triple and Cargo target are distinct strings; both must be set.
  # The Cargo env-var name is derived from the target via the
  # `SCREAMING_SNAKE_CASE` transform that cargo applies.
  rustTarget = "x86_64-pc-windows-gnu";

  baseArgs = builtins.removeAttrs userArgs [
    "depsBuildBuild"
    "nativeBuildInputs"
    "buildInputs"
    "env"
  ];
in
crossPkgs.rustPlatform.buildRustPackage (
  baseArgs
  // {
    doCheck = userArgs.doCheck or false;

    depsBuildBuild = userDepsBuildBuild ++ [ pkgs.stdenv.cc ];

    nativeBuildInputs = userNativeBuildInputs ++ [
      crossPkgs.stdenv.cc
      pkgs.pkg-config
    ];

    buildInputs = userBuildInputs ++ [
      crossPkgs.windows.pthreads
      # nixpkgs builds its mingw-w64 toolchain with the `mcf` thread
      # model, so `libgcc_eh.a` (linked into any Rust binary that
      # unwinds — i.e. all of them) references `_MCF_*` symbols that
      # only libmcfgthread provides. Without it every non-trivial
      # cross-build fails at the final link with screen-fulls of
      # `undefined reference to _MCF_tls_key_new` etc.
      crossPkgs.windows.mcfgthreads
    ];

    env = (
      {
        CARGO_BUILD_TARGET = rustTarget;
        CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "${targetPrefix}gcc";
        WINDRES = "${targetPrefix}windres";
        HOST_CC = "${pkgs.stdenv.cc}/bin/cc";
      }
      // userEnv
      # Merge RUSTFLAGS rather than clobbering — callers legitimately
      # extend link args (system libs for crates whose build.rs
      # doesn't self-register them).
      // (
        let
          defaultRustflags = "-C link-arg=-lmcfgthread";
          userRustflags = userEnv.CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS or "";
        in
        {
          CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS =
            if userRustflags == "" then defaultRustflags else "${defaultRustflags} ${userRustflags}";
        }
      )
    );

    meta = (userArgs.meta or { }) // {
      platforms = [ "x86_64-windows" ];
    };
  }
)
