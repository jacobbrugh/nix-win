# The `lib.hm` namespace for the winHome class — the subset of
# home-manager's library that home-manager-compatible modules rely on.
# dag.nix and types-dag.nix are vendored VERBATIM from home-manager (MIT);
# strings.nix is trimmed to storeFileName. Keeping the sources byte-equal
# to upstream is what guarantees `lib.hm.dag.entryAfter [ "writeBoundary" ]`
# and `lib.hm.types.dagOf` behave identically under both classes.
{ lib }:
{
  dag = import ./dag.nix { inherit lib; };
  types = import ./types-dag.nix { inherit lib; };
  strings = import ./strings.nix { inherit lib; };
}
