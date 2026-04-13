# Security policy

nix-win is an experimental personal project. I can't guarantee a response
time, but I do want to know about real security issues so they can be fixed.

## Reporting a vulnerability

Please use GitHub's [private vulnerability
reporting](https://github.com/jacobbrugh/nix-win/security/advisories/new) to
disclose security issues. Do not file public issues or pull requests for
exploitable problems.

Please include:

- A description of the issue and its impact
- Steps to reproduce (a minimal flake or PowerShell snippet is ideal)
- The commit SHA you observed it on

## Scope

**In scope**

- Command injection, arbitrary file overwrite, privilege escalation, or
  credential exposure triggered by evaluating a malicious or adversarial
  consumer flake
- Vulnerabilities in the build and activation pipeline — `pkgs/nix-win/nix-win.ps1`,
  generated `activate.ps1`, file-placement logic, DSC YAML generation

**Out of scope**

- Vulnerabilities in WSL, PowerShell, Nix, Scoop, WinGet, or DSC themselves —
  please report those to their respective upstream projects
- Issues that require local administrator access on a machine the attacker
  already controls
