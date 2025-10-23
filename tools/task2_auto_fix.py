#!/usr/bin/env python3
"""Automated syntax repair tool for Luau bundle files.

This command applies the limited "safe" fixes described in the Task 2
specification.  The implementation intentionally focuses on deterministic
textual rewrites so that no gameplay behaviour is altered.

Usage:
    python tools/task2_auto_fix.py \
        --bundle /mnt/data/FruitSmash_lua_bundle.json \
        --diagnostics /mnt/data/DiagnosticsReport.json \
        --out-bundle /mnt/data/FruitSmash_lua_bundle_fixed.json \
        --out-diagnostics /mnt/data/DiagnosticsReport_fixed.json

All arguments are optional and default to the paths above to match the
assignment's expectations.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

# The Luau syntax checker ships in this repository and already understands the
# bundled JSON layout.  Re-using its helpers keeps behaviour aligned with Task 1.
if __package__ is None:
    sys.path.append(str(Path(__file__).resolve().parent))
from luau_syntax_checker import analyze_script, load_scripts  # type: ignore


@dataclass
class ScriptEntry:
    """Mutable handle for a bundled script."""

    path: str
    parent: Dict[str, object]
    key: str

    def get_source(self) -> str:
        value = self.parent[self.key]
        assert isinstance(value, str)
        return value

    def set_source(self, source: str) -> None:
        self.parent[self.key] = source


class AutoFixer:
    """Applies the Task 2 safe auto-fix rules to Luau source."""

    _type_arrow_pattern = re.compile(r"(type\s+\w+\s*=\s*\([^)]*\))\s*=\s*")
    _statement_boundary_pattern = re.compile(r"([)\]\}])(\s*\n\s*)(?=[({])")
    _duplicate_commas_pattern = re.compile(r",\s*,+")
    _trailing_comma_pattern = re.compile(r",(?P<ws>\s*)(?P<close>[)\]\}])")

    def apply(self, source: str) -> str:
        updated = source
        updated = self._fix_type_arrows(updated)
        updated = self._fix_ambiguous_statement_boundaries(updated)
        updated = self._remove_duplicate_commas(updated)
        updated = self._close_tables_before_type(updated)
        updated = self._append_missing_closers(updated)
        return updated

    def _fix_type_arrows(self, source: str) -> str:
        return self._type_arrow_pattern.sub(r"\1 -> ", source)

    def _fix_ambiguous_statement_boundaries(self, source: str) -> str:
        return self._statement_boundary_pattern.sub(lambda m: f"{m.group(1)};{m.group(2)}", source)

    def _remove_duplicate_commas(self, source: str) -> str:
        updated = self._duplicate_commas_pattern.sub(",", source)
        return self._trailing_comma_pattern.sub(lambda m: f"{m.group('ws')}{m.group('close')}", updated)

    def _close_tables_before_type(self, source: str) -> str:
        result: List[str] = []
        index = 0
        length = len(source)
        while index < length:
            brace_index = source.find("{", index)
            if brace_index == -1:
                result.append(source[index:])
                break
            result.append(source[index:brace_index])
            lookahead = brace_index + 1
            whitespace = []
            while lookahead < length and source[lookahead] in " \t\r\n":
                whitespace.append(source[lookahead])
                lookahead += 1
            if source.startswith("type", lookahead):
                result.append("{}")
                if whitespace:
                    result.append("".join(whitespace))
                index = lookahead
            else:
                result.append("{")
                if whitespace:
                    result.append("".join(whitespace))
                index = lookahead
        return "".join(result)

    def _append_missing_closers(self, source: str) -> str:
        stack: List[str] = []
        index = 0
        length = len(source)
        while index < length:
            ch = source[index]
            # Handle line and block comments first.
            if ch == "-" and source.startswith("--", index):
                index = self._skip_comment(source, index)
                continue
            # Long strings such as [[ ... ]] or [=[ ... ]=]
            if ch == "[":
                end = self._skip_long_bracket(source, index)
                if end is not None:
                    index = end
                    continue
            if ch in ('"', "'"):
                index = self._skip_quoted_string(source, index)
                continue
            if ch in "({[":
                stack.append(ch)
            elif ch in ")}]":
                if stack and self._matching(stack[-1]) == ch:
                    stack.pop()
            index += 1
        if not stack:
            return source
        closing = "".join(self._matching(ch) for ch in reversed(stack))
        if not source.endswith("\n"):
            source += "\n"
        return source + closing

    def _skip_comment(self, source: str, index: int) -> int:
        assert source.startswith("--", index)
        index += 2
        if index < len(source) and source[index] == "[":
            bracket_end = self._skip_long_bracket(source, index)
            if bracket_end is not None:
                return bracket_end
        while index < len(source) and source[index] != "\n":
            index += 1
        return index

    def _skip_long_bracket(self, source: str, index: int) -> Optional[int]:
        # Long brackets look like [==[ ... ]==].  index points at the opening '['.
        if index + 1 >= len(source):
            return None
        equals = 0
        marker_index = index + 1
        while marker_index < len(source) and source[marker_index] == "=":
            equals += 1
            marker_index += 1
        if marker_index >= len(source) or source[marker_index] != "[":
            return None
        marker = "]" + "=" * equals + "]"
        closing_index = source.find(marker, marker_index + 1)
        if closing_index == -1:
            return None
        return closing_index + len(marker)

    def _skip_quoted_string(self, source: str, index: int) -> int:
        quote = source[index]
        index += 1
        while index < len(source):
            ch = source[index]
            if ch == "\\":
                index += 2
                continue
            index += 1
            if ch == quote:
                break
        return index

    @staticmethod
    def _matching(ch: str) -> str:
        return {"(": ")", "[": "]", "{": "}"}[ch]


def collect_script_entries(bundle: object) -> List[ScriptEntry]:
    """Return editable handles for each script inside the bundle."""

    entries: List[ScriptEntry] = []

    def handle_dict(container: Dict[str, object]) -> None:
        path = container.get("path") or container.get("name")
        if not isinstance(path, str):
            return
        for key in ("content", "source", "Source"):
            value = container.get(key)
            if isinstance(value, str):
                entries.append(ScriptEntry(path=path, parent=container, key=key))
                return

    if isinstance(bundle, list):
        for item in bundle:
            if isinstance(item, dict):
                handle_dict(item)
    elif isinstance(bundle, dict):
        if "files" in bundle and isinstance(bundle["files"], list):
            for item in bundle["files"]:
                if isinstance(item, dict):
                    handle_dict(item)
        else:
            for key, value in list(bundle.items()):
                if isinstance(value, str):
                    entries.append(ScriptEntry(path=key, parent=bundle, key=key))
    return entries


def load_json(path: Path) -> object:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json(path: Path, data: object) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def parse_diagnostics(path: Path) -> Tuple[List[dict], List[str]]:
    if not path.exists():
        return [], []
    with path.open("r", encoding="utf-8") as handle:
        try:
            data = json.load(handle)
        except json.JSONDecodeError:
            return [], []
    if not isinstance(data, list):
        return [], []
    paths = [entry.get("path") for entry in data if isinstance(entry, dict) and isinstance(entry.get("path"), str)]
    return data, [p for p in paths if isinstance(p, str)]


def build_diagnostics(bundle_path: Path) -> List[dict]:
    diagnostics: List[dict] = []
    for script_path, source in load_scripts(bundle_path):
        result = analyze_script(script_path, source)
        if result is not None:
            diagnostics.append(result)
    return diagnostics


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Apply Task 2 safe Luau auto-fixes")
    parser.add_argument("--bundle", type=Path, default=Path("/mnt/data/FruitSmash_lua_bundle.json"))
    parser.add_argument(
        "--diagnostics",
        type=Path,
        default=Path("/mnt/data/DiagnosticsReport.json"),
    )
    parser.add_argument(
        "--out-bundle",
        type=Path,
        default=Path("/mnt/data/FruitSmash_lua_bundle_fixed.json"),
    )
    parser.add_argument(
        "--out-diagnostics",
        type=Path,
        default=Path("/mnt/data/DiagnosticsReport_fixed.json"),
    )
    args = parser.parse_args(argv)

    if not args.bundle.exists():
        print(f"Input bundle not found: {args.bundle}", file=sys.stderr)
        return 1

    bundle_data = load_json(args.bundle)
    diagnostics, paths_with_errors = parse_diagnostics(args.diagnostics)

    fixer = AutoFixer()
    entries = collect_script_entries(bundle_data)
    changed_files: List[str] = []
    target_paths = set(paths_with_errors)
    for entry in entries:
        if target_paths and entry.path not in target_paths:
            continue
        original_source = entry.get_source()
        fixed_source = fixer.apply(original_source)
        if fixed_source != original_source:
            entry.set_source(fixed_source)
            changed_files.append(entry.path)

    args.out_bundle.parent.mkdir(parents=True, exist_ok=True)
    save_json(args.out_bundle, bundle_data)

    updated_diagnostics = build_diagnostics(args.out_bundle)

    summary = {
        "autoFixApplied": True,
        "fixedFiles": sorted(set(changed_files)),
        "appliedRules": [
            "type-arrow-rewrite",
            "insert-semicolon-before-brace-or-paren",
            "remove-redundant-commas",
            "close-table-before-type",
            "append-missing-closers",
        ],
        "remainingDiagnostics": updated_diagnostics,
        "originalDiagnostics": diagnostics,
    }
    args.out_diagnostics.parent.mkdir(parents=True, exist_ok=True)
    save_json(args.out_diagnostics, summary)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
