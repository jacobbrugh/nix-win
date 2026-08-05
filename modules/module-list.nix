# All base modules for nix-win.
# New modules must be added here to be included in evaluation.
[
  ./system.nix
  ./users.nix
  ./misc/assertions.nix
  ./networking.nix
  ./compat.nix
  ./files.nix
  ./links.nix
  ./packages.nix
  ./environment.nix
  ./activation.nix
  ./scoop.nix
  ./winget.nix
  ./powershell.nix
  ./dsc
  ./autohotkey.nix
  ./komorebi.nix
  ./wslconfig.nix
  ./windows-terminal.nix
]
