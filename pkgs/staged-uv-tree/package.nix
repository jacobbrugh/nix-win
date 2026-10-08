# staged-uv-tree — builds the Windows runtime tree for home.stagedUvTools
# (see modules/home/staged-uv-tools.nix). mypy --strict and pytest run in the
# checkPhase, so every evaluation that stages a tool type-checks and tests the
# program that stages it.
{ python3Packages }:
python3Packages.buildPythonApplication {
  pname = "staged-uv-tree";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ python3Packages.setuptools ];
  nativeCheckInputs = [
    python3Packages.mypy
    python3Packages.pytest
  ];
  checkPhase = ''
    runHook preCheck
    mypy --strict --config-file pyproject.toml src tests
    PYTHONPATH="$PWD/src:$PYTHONPATH" pytest -q tests
    runHook postCheck
  '';
  pythonImportsCheck = [ "staged_uv_tree" ];
  meta.mainProgram = "staged-uv-tree";
}
