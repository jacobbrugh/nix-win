# All base modules for nix-win.
# New modules must be added here to be included in evaluation.
[
  ./system.nix
  ./users.nix
  ./misc/assertions.nix
  ./networking.nix
  ./home-manager.nix
  ./environment-files.nix
  ./system-packages.nix
  ./activation.nix
  ./scoop.nix
  ./scheduled-tasks.nix
  ./winget.nix
  ./powershell.nix
  ./dsc
]
