"""Helpers for loading repo-local Python scripts in unit tests."""

from __future__ import annotations

import importlib.util
import types
import uuid
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_script(relative_path: str) -> types.ModuleType:
    """Load a Python script by relative repo path as a fresh module."""

    script_path = REPO_ROOT / relative_path
    module_name = f"nemobot_test_{script_path.stem}_{uuid.uuid4().hex}"
    spec = importlib.util.spec_from_file_location(module_name, script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load script: {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
