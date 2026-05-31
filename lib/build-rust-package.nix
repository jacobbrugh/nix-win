# Windows Rust cross-compile builders — compile a Rust crate from Linux to
# x86_64-pc-windows-gnu using `pkgsCross.mingwW64`.
#
# This module exposes two top-level builders that share one cross-config
# helper (`applyWindowsCross`), so the MinGW target/linker/library plumbing
# lives in exactly one place:
#
#   - buildWindowsRustPackage — mirrors `rustPlatform.buildRustPackage`.
#     Owns its toolchain (`crossPkgs.rustPlatform`); call it with the same
#     args you'd pass buildRustPackage (pname, version, src, cargoHash, …).
#
#   - buildWindowsCranePackage — mirrors crane's `craneLib.buildPackage`.
#     The crane toolchain (a single build-host rustc carrying the
#     windows-gnu std, via rust-overlay) is not in nixpkgs the way
#     `crossPkgs.rustPlatform` is, so the caller supplies its own
#     windows-targeted `craneLib`. `cargoArtifacts` is optional and, when
#     omitted, is auto-derived via `craneLib.buildDepsOnly` on the same
#     cross-applied args — exactly as crane's buildPackage defaults it — so
#     the cached dependency layer is built for the Windows target too.
#
# The cross plumbing `applyWindowsCross` folds in:
#   - CARGO_BUILD_TARGET (distinct from the Nix cross triple)
#   - CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER (MinGW gcc wrapper)
#   - WINDRES (for the `embed-resource` crate and similar RC-file consumers)
#   - HOST_CC (so build-scripts that need a host cc don't leak target cc)
#   - depsBuildBuild additions (build-scripts + proc-macros run on the build host)
#   - windows.pthreads + windows.mcfgthreads in buildInputs
#   - the -lmcfgthread link arg (merged into, not clobbering, caller RUSTFLAGS)
#
# Tests are disabled by default (`doCheck = false`): we can't execute
# Windows binaries on the Linux build host without Wine.
#
# Usage (buildRustPackage-style):
#   inputs.nix-win.lib.${system}.buildWindowsRustPackage {
#     pname = "foo"; version = "0.1.0"; src = ./.; cargoHash = "sha256-…";
#   }
#
# Usage (crane-style):
#   inputs.nix-win.lib.${system}.buildWindowsCranePackage {
#     craneLib = (crane.mkLib pkgs).overrideToolchain
#       (p: p.rust-bin.stable.latest.minimal.override {
#         targets = [ "x86_64-pc-windows-gnu" ];
#       });
#     pname = "foo"; version = "0.1.0"; src = ./.;
#   }
#
# Both produce PE32+ executables under `$out/bin/`. Pass the whole output
# directory to `win.packages.<name>.package` to ship it.

{ pkgs }:

let
  crossPkgs = pkgs.pkgsCross.mingwW64;
  targetPrefix = crossPkgs.stdenv.cc.targetPrefix;

  # Nix cross triple and Cargo target are distinct strings; both must be set.
  # The Cargo env-var name is derived from the target via the
  # `SCREAMING_SNAKE_CASE` transform that cargo applies.
  rustTarget = "x86_64-pc-windows-gnu";

  crossEnv = {
    CARGO_BUILD_TARGET = rustTarget;
    CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "${targetPrefix}gcc";
    WINDRES = "${targetPrefix}windres";
    HOST_CC = "${pkgs.stdenv.cc}/bin/cc";
  };

  defaultRustflags = "-C link-arg=-lmcfgthread";

  # Fold the Windows cross config into a caller's args attrset. Lists and
  # RUSTFLAGS are merged (not clobbered) so callers can extend them — e.g.
  # add a system lib for a crate whose build.rs doesn't self-register it.
  # Shared by both builders; the only thing that differs between them is the
  # builder the merged args are handed to.
  applyWindowsCross =
    args:
    let
      userEnv = args.env or { };
      userRustflags = userEnv.CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS or "";
      baseArgs = builtins.removeAttrs args [
        "depsBuildBuild"
        "nativeBuildInputs"
        "buildInputs"
        "env"
      ];
    in
    baseArgs
    // {
      doCheck = args.doCheck or false;

      depsBuildBuild = (args.depsBuildBuild or [ ]) ++ [ pkgs.stdenv.cc ];

      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
        crossPkgs.stdenv.cc
        pkgs.pkg-config
      ];

      buildInputs = (args.buildInputs or [ ]) ++ [
        crossPkgs.windows.pthreads
        # nixpkgs builds its mingw-w64 toolchain with the `mcf` thread
        # model, so `libgcc_eh.a` (linked into any Rust binary that
        # unwinds — i.e. all of them) references `_MCF_*` symbols that
        # only libmcfgthread provides. Without it every non-trivial
        # cross-build fails at the final link with screen-fulls of
        # `undefined reference to _MCF_tls_key_new` etc.
        crossPkgs.windows.mcfgthreads
      ];

      env =
        crossEnv
        // userEnv
        // {
          CARGO_TARGET_X86_64_PC_WINDOWS_GNU_RUSTFLAGS =
            if userRustflags == "" then defaultRustflags else "${defaultRustflags} ${userRustflags}";
        };
    };

  # buildRustPackage uses crossPkgs (its nixpkgs hostPlatform IS
  # x86_64-windows), so tagging meta.platforms accordingly is correct and
  # passes check-meta. The crane builder instead builds on the native pkgs
  # and cross-emits via CARGO_BUILD_TARGET (hostPlatform stays the build
  # system), so it must NOT carry an x86_64-windows platforms tag or
  # check-meta refuses it — hence this tag lives here, not in applyWindowsCross.
  buildWindowsRustPackage =
    args:
    crossPkgs.rustPlatform.buildRustPackage (
      (applyWindowsCross args)
      // {
        meta = (args.meta or { }) // {
          platforms = [ "x86_64-windows" ];
        };
      }
    );

  buildWindowsCranePackage =
    {
      craneLib,
      cargoArtifacts ? null,
      ...
    }@args:
    let
      base = applyWindowsCross (
        builtins.removeAttrs args [
          "craneLib"
          "cargoArtifacts"
        ]
      );
      deps = if cargoArtifacts != null then cargoArtifacts else craneLib.buildDepsOnly base;
    in
    craneLib.buildPackage (base // { cargoArtifacts = deps; });
in
{
  inherit buildWindowsRustPackage buildWindowsCranePackage;
}
