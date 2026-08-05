# Mirrors home-manager's modules/lib/stdlib-extended.nix: extend whatever
# nixpkgs lib the caller provides with the (vendored) `hm` namespace. The
# extended lib is the lib that evalModules runs on, so every winHome module
# sees `lib.hm.*` while keeping the caller's own extensions intact.
nixpkgsLib:
nixpkgsLib.extend (
  self: _super: {
    hm = import ./default.nix { lib = self; };
  }
)
