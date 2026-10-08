# run-hidden — the launcher behind scheduledTasks.<name>.hideConsole (see
# run-hidden.c for what it does and why). Cross-compiled with the MinGW
# toolchain lib/build-rust-package.nix also uses; one C file, no runtime
# dependencies beyond the Win32 API.
{ lib, pkgsCross }:
pkgsCross.mingwW64.stdenv.mkDerivation {
  pname = "run-hidden";
  version = "0.1.0";

  src = ./run-hidden.c;
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -Werror -municode -mwindows -static -o run-hidden.exe "$src"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 run-hidden.exe "$out/bin/run-hidden.exe"
    runHook postInstall
  '';

  # environment.systemPackages stages it under %ProgramData%\<relativePath>.
  passthru.nixWin.relativePath = "nix-win/Programs/run-hidden";

  meta = {
    description = "Run a console program with no window, inside a kill-on-stop job, returning its exit code";
    platforms = lib.platforms.windows;
    mainProgram = "run-hidden";
  };
}
