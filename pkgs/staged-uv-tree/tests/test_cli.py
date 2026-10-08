from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from staged_uv_tree.cli import StageError, find_entry_point, main, merge, stage


def _package(root: Path, name: str, files: dict[str, str]) -> Path:
    site = root / name / "site-packages"
    for rel, text in files.items():
        path = site / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return site


def _app(root: Path) -> Path:
    return _package(
        root,
        "app",
        {
            "app_mod/__init__.py": "",
            "app_mod/cli.py": (
                "import lib_mod\n"
                "def main() -> int:\n"
                "    print(lib_mod.greet())\n"
                "    return 3\n"
            ),
            "app_mod/__pycache__/cli.cpython-312.pyc": "stale",
            "app_mod-1.0.dist-info/entry_points.txt": (
                "[console_scripts]\napp = app_mod.cli:main\nApp-Extra = app_mod.cli:main\n"
            ),
        },
    )


def _lib(root: Path) -> Path:
    return _package(root, "lib", {"lib_mod/__init__.py": "def greet() -> str:\n    return 'hi'\n"})


def test_stage_merges_closure_and_launcher_runs_entry_point(tmp_path: Path) -> None:
    out = tmp_path / "out"
    stage([_app(tmp_path), _lib(tmp_path)], out, "app", ">=3.12,<3.13")

    assert (out / "app_mod" / "cli.py").is_file()
    assert (out / "lib_mod" / "__init__.py").is_file()
    assert not (out / "app_mod" / "__pycache__").exists()

    launcher = (out / "launch.py").read_text(encoding="utf-8")
    assert '# requires-python = ">=3.12,<3.13"' in launcher
    assert "# dependencies = []" in launcher

    run = subprocess.run(
        [sys.executable, "-I", str(out / "launch.py")], capture_output=True, text=True, check=False
    )
    assert run.stdout.strip() == "hi"
    assert run.returncode == 3


def test_entry_point_names_are_case_sensitive(tmp_path: Path) -> None:
    out = tmp_path / "out"
    merge([_app(tmp_path)], out)
    assert find_entry_point(out, "App-Extra").attr == "main"
    with pytest.raises(StageError, match="found none"):
        find_entry_point(out, "app-extra")


def test_missing_main_program_fails(tmp_path: Path) -> None:
    with pytest.raises(StageError, match="'nope'"):
        stage([_app(tmp_path)], tmp_path / "out", "nope", ">=3.12")


def test_native_extension_fails_naming_the_file(tmp_path: Path) -> None:
    native = _package(tmp_path, "native", {"fast/_speedups.cpython-312-x86_64-linux-gnu.so": "ELF"})
    with pytest.raises(StageError, match=r"fast/_speedups\.cpython-312-x86_64-linux-gnu\.so"):
        stage([_app(tmp_path), native], tmp_path / "out", "app", ">=3.12")


def test_conflicting_files_fail_identical_files_merge(tmp_path: Path) -> None:
    a = _package(tmp_path, "a", {"shared/x.py": "one"})
    same = _package(tmp_path, "same", {"shared/x.py": "one"})
    merge([a, same], tmp_path / "ok")
    other = _package(tmp_path, "other", {"shared/x.py": "two"})
    with pytest.raises(StageError, match="different contents"):
        merge([a, other], tmp_path / "bad")


def test_main_reports_errors_and_exits_nonzero(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    code = main(
        ["--out", str(tmp_path / "out"), "--main-program", "app", "--requires-python", ">=3.12",
         str(tmp_path / "missing")]
    )
    assert code == 1
    assert "not a site-packages directory" in capsys.readouterr().err
