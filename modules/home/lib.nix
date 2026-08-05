# The `lib` config namespace (home-manager's modules/misc/lib.nix analog):
# modules define helper functions/constants under config.lib.*. Ships
# config.lib.file.mkOutOfStoreSymlink with home-manager's call signature —
# under winHome the tagged value routes the home.file entry into the link
# manifest, deployed as an NTFS junction (directories) or symlink (files)
# instead of a copied file. The argument should be a Windows path string
# (build it from config.home.homeDirectory); `$env:` references are
# expanded by the CLI at activation.
{ lib, ... }:
{
  options.lib = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    default = { };
    description = ''
      This option allows modules to define helper functions,
      constants, etc.
    '';
  };

  config.lib.file.mkOutOfStoreSymlink = path: {
    _type = "winOutOfStoreSymlink";
    target = toString path;
  };
}
