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

      # Filter deps to only reference entries that actually exist
      effectiveDeps =
        name:
        builtins.filter (d: builtins.hasAttr d entries) (entries.${name}.deps or [ ]);

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
