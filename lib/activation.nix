# DAG-based activation script ordering for nix-win.
# Each activation entry has a name, text, and list of dependencies.
# Entries are topologically sorted and concatenated into the final activation script.
{ lib }:
let
  # Simple topological sort on activation entries
  # entries: attrset of { text: string; deps: [string]; }
  # Returns: list of { name: string; text: string; } in dependency order
  sortActivation =
    entries:
    let
      names = builtins.attrNames entries;

      # A dep naming a non-existent entry is an error, not a no-op: silently
      # dropping it reorders the script instead of failing, which is invisible
      # at eval and only shows up as wrong runtime behavior.
      effectiveDeps =
        name:
        map (
          d:
          if builtins.hasAttr d entries then
            d
          else
            throw "nix-win: activation script '${name}' depends on '${d}', which does not exist. (If this was a nix-win built-in phase, it may have moved to the winHome class; see the migration notes in the README.)"
        ) (entries.${name}.deps or [ ]);

      # Kahn's algorithm (iterative via fold)
      go =
        { sorted, remaining }:
        if remaining == [ ] then
          sorted
        else
          let
            # Find entries whose deps are all in sorted
            sortedNames = map (e: e.name) sorted;
            ready = builtins.filter (
              name: builtins.all (d: builtins.elem d sortedNames) (effectiveDeps name)
            ) remaining;
          in
          if ready == [ ] then
            throw "nix-win: circular dependency in activation scripts among: ${builtins.concatStringsSep ", " remaining}"
          else
            go {
              sorted = sorted ++ map (name: { inherit name; inherit (entries.${name}) text; }) ready;
              remaining = builtins.filter (name: !(builtins.elem name ready)) remaining;
            };
    in
    go {
      sorted = [ ];
      remaining = names;
    };

  # Concatenate sorted activation entries into a single PowerShell script
  mkActivationScript =
    entries:
    let
      sorted = sortActivation entries;
      sections = map (
        entry:
        ''
          # ── ${entry.name} ──────────────────────────────────────────────
          ${entry.text}
        ''
      ) sorted;
    in
    builtins.concatStringsSep "\n" sections;

in
{
  inherit sortActivation mkActivationScript;
}
