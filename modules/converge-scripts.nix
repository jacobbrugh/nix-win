# system.convergeScripts — named test/set pairs, converged in one process.
#
# This is the native replacement for PSDesiredStateConfiguration/Script under
# the Windows PowerShell adapter, which cost a full 5.1 process spawn per
# resource (measured at 1.40 s each, ~21 s for thirteen) to run a few lines of
# PowerShell we wrote ourselves anyway.
#
# There is deliberately no cross-platform option name to borrow here.
# NixOS's and nix-darwin's `system.activationScripts` run unconditionally and
# have no test phase; nix-win keeps that option, with the same name and shape,
# for unconditional work. This option is for the other thing DSC gave us and
# activation scripts do not: a convergence check that reports `ok` when there
# is nothing to do, so a switch log distinguishes "checked, fine" from "did
# something".
{
  config,
  lib,
  ...
}:
let
  cfg = config.system.convergeScripts;

  enabled = lib.filterAttrs (_: s: s.enable) cfg;

  # Stable order: priority first, then name. DSC applied resources in document
  # order, which for a Nix attrset is alphabetical, so plain name ordering
  # reproduces today's behaviour; `priority` exists for the cases where one
  # script genuinely must precede another.
  ordered = lib.sort (a: b: if a.priority != b.priority then a.priority < b.priority else a.name < b.name) (
    lib.mapAttrsToList (name: s: { inherit name; inherit (s) priority testScript setScript; }) enabled
  );

  # PowerShell single-quoted literal: the only escape is a doubled quote.
  # (lib.escapeShellArg is POSIX and would emit the wrong thing here.)
  psStr = s: "'" + (lib.replaceStrings [ "'" ] [ "''" ] s) + "'";

  renderOne = s: ''
    Invoke-NixWinItem -Name ${psStr s.name} -Test {
    ${s.testScript}
    } -Set {
    ${s.setScript}
    }
  '';
in
{
  options.system.convergeScripts = lib.mkOption {
    default = { };
    description = ''
      Named convergence checks, run in a single PowerShell process during
      activation. Each entry reports `ok`, `changed` or `FAILED` on its own
      line; a failure does not prevent the remaining entries from running.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to run this check.";
          };

          priority = lib.mkOption {
            type = lib.types.int;
            default = 1000;
            description = ''
              Ordering within the phase; lower runs first. Entries with equal
              priority run in name order.
            '';
          };

          testScript = lib.mkOption {
            type = lib.types.lines;
            description = ''
              PowerShell that returns `$true` when the desired state already
              holds. Runs in its own scriptblock, so `return` is safe.

              Emit nothing except the verdict: anything written to the success
              stream becomes part of the result, and the last value emitted is
              what counts.
            '';
          };

          setScript = lib.mkOption {
            type = lib.types.lines;
            description = "PowerShell that establishes the desired state. Runs only when testScript returned false.";
          };
        };
      }
    );
  };

  config = lib.mkIf (enabled != { }) {
    system.activationScripts.convergeScripts = {
      deps = [ "files" ];
      text = ''
        Write-Host "nix-win: running convergence checks..." -ForegroundColor Cyan
        ${lib.concatMapStringsSep "\n" renderOne ordered}
      '';
    };
  };
}
