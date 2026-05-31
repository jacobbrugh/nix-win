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
    # The cc-rs crate (libz-sys, openssl-src, …) compiles C for the TARGET and
    # picks its compiler from CC_<target>/CXX_<target>/AR_<target>. nixpkgs'
    # cross stdenv would export these, but crane builds on the native stdenv, so
    # without them cc-rs falls back to the host `gcc` and target C fails (e.g.
    # zlib: `implicit declaration of 'write'` because there's no unistd.h on
    # Windows). Point them at the MinGW cross toolchain.
    CC_x86_64_pc_windows_gnu = "${targetPrefix}gcc";
    CXX_x86_64_pc_windows_gnu = "${targetPrefix}g++";
    AR_x86_64_pc_windows_gnu = "${targetPrefix}ar";
    # windows.pthreads/mcfgthreads are TARGET-only libs. In a native stdenv,
    # putting them in buildInputs leaks their headers into the single
    # NIX_CFLAGS_COMPILE that host cc invocations also read, so a host build dep
    # (e.g. libgit2-sys via a build.rs) picks up MinGW pthread.h and fails with
    # glibc type conflicts. Scope them to the target instead: headers via the
    # cc-rs CFLAGS_<target>, libs via the target RUSTFLAGS `-L` below.
    CFLAGS_x86_64_pc_windows_gnu = "-I${crossPkgs.windows.pthreads}/include -I${crossPkgs.windows.mcfgthreads}/include";
    CXXFLAGS_x86_64_pc_windows_gnu = "-I${crossPkgs.windows.pthreads}/include -I${crossPkgs.windows.mcfgthreads}/include";
  };

  # `-L` the MinGW thread libs onto the TARGET link only (not buildInputs, which
  # would leak to host compiles). mcfgthreads: nixpkgs builds its mingw-w64
  # toolchain with the `mcf` thread model, so `libgcc_eh.a` (linked into any Rust
  # binary that unwinds — i.e. all of them) references `_MCF_*` symbols only
  # libmcfgthread provides; without `-lmcfgthread` the final link fails with
  # screen-fulls of `undefined reference to _MCF_tls_key_new` etc.
  defaultRustflags =
    "-L native=${crossPkgs.windows.pthreads}/lib "
    + "-L native=${crossPkgs.windows.mcfgthreads}/lib "
    + "-C link-arg=-lmcfgthread";

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

      # No windows.pthreads/mcfgthreads here — they are TARGET-only and would
      # leak to host compiles (see crossEnv above); they reach the target via
      # CFLAGS_<target> (headers) and the `-L` in defaultRustflags (libs).
      buildInputs = args.buildInputs or [ ];

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

  # Mirrors crane's `craneLib.buildDepsOnly`: compiles the third-party crate
  # closure for the Windows target. crane builds this against a stubbed dummy
  # source tree, so pass only deps-relevant args here — src/dummySrc,
  # cargoExtraArgs, prePatch — and NOT package-only phases like a postPatch that
  # edits real workspace files. Feed the result to buildWindowsCranePackage's
  # `cargoArtifacts`, exactly as you'd pair craneLib.buildDepsOnly with
  # craneLib.buildPackage.
  buildWindowsCraneDepsOnly =
    { craneLib, ... }@args:
    craneLib.buildDepsOnly (applyWindowsCross (builtins.removeAttrs args [ "craneLib" ]));

  # Mirrors crane's `craneLib.buildPackage`: builds the package with the
  # caller-supplied windows-targeted `craneLib`. As in crane, `cargoArtifacts`
  # is optional and defaults to a buildDepsOnly over the same args — so when the
  # package args carry phases the deps build must not run, build the deps layer
  # with buildWindowsCraneDepsOnly and pass it in explicitly.
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
  inherit buildWindowsRustPackage buildWindowsCraneDepsOnly buildWindowsCranePackage;
}
