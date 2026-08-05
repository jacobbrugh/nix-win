# programs.git — the home-manager-compatible subset. Renders
# ~/.config/git/{config,ignore,attributes} from the same option shapes
# home-manager uses (settings/ignores/attributes), so a shared git module
# evaluates unchanged under both classes. Git itself is NOT installed by
# this module (`package` defaults to null and stays null — the binary comes
# from a package manager like scoop).
{
  config,
  lib,
  ...
}:
let
  cfg = config.programs.git;

  # home-manager's gitIniType, verbatim shape.
  gitIniType =
    with lib.types;
    let
      primitiveType = either str (either bool int);
      multipleType = either primitiveType (listOf primitiveType);
      sectionType = attrsOf multipleType;
      supersectionType = attrsOf (either multipleType sectionType);
    in
    attrsOf supersectionType;

  settingsFragments = if builtins.isList cfg.settings then cfg.settings else [ cfg.settings ];

  renderedIni = lib.concatStringsSep "\n" (
    lib.filter (text: builtins.match "[[:space:]]*" text == null) (
      map lib.generators.toGitINI settingsFragments
    )
  );
in
{
  options.programs.git = {
    enable = lib.mkEnableOption "Git configuration management";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Accepted for home-manager compatibility; never installed under
        winHome (git comes from a Windows package manager).
      '';
    };

    settings = lib.mkOption {
      type = lib.types.either gitIniType (lib.types.listOf gitIniType);
      default = { };
      description = ''
        Git configuration, rendered to ~/.config/git/config with the
        same generator semantics as home-manager (lib.generators.toGitINI,
        one fragment per list element).
      '';
    };

    ignores = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of paths that should be globally ignored.";
    };

    attributes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of defining attributes set globally.";
    };
  };

  config = lib.mkIf cfg.enable {
    xdg.configFile = lib.mkMerge [
      {
        "git/config" = {
          text = renderedIni;
          lineEnding = "lf";
        };
      }
      (lib.mkIf (cfg.ignores != [ ]) {
        "git/ignore" = {
          text = lib.concatStringsSep "\n" cfg.ignores + "\n";
          lineEnding = "lf";
        };
      })
      (lib.mkIf (cfg.attributes != [ ]) {
        "git/attributes" = {
          text = lib.concatStringsSep "\n" cfg.attributes + "\n";
          lineEnding = "lf";
        };
      })
    ];
  };
}
