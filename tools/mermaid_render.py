#!/usr/bin/env python3
"""Lint and optionally render Mermaid diagrams stored in markdown files."""

from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence

MERMAID_KEYWORDS = {
    "flowchart",
    "graph",
    "sequenceDiagram",
    "classDiagram",
    "stateDiagram",
    "erDiagram",
    "journey",
    "gantt",
    "timeline",
    "pie",
    "mindmap",
    "quadrantChart",
    "gitGraph",
}


@dataclass
class MermaidBlock:
    file_path: Path
    start_line: int
    index: int
    code: str
    diagram_type: str | None = None

    @property
    def slug(self) -> str:
        rel_path = self.file_path.as_posix()
        base = f"{rel_path}_{self.index}"
        return re.sub(r"[^0-9A-Za-z]+", "_", base).strip("_") or "diagram"


def iter_markdown_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*.md")):
        if path.is_file():
            yield path


def extract_blocks(file_path: Path) -> List[MermaidBlock]:
    blocks: List[MermaidBlock] = []
    in_block = False
    block_lines: List[str] = []
    start_line = 0
    index = 0

    with file_path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            stripped = raw_line.strip()
            if not in_block:
                if stripped.lower().startswith("```mermaid"):
                    in_block = True
                    block_lines = []
                    start_line = line_number + 1
                    index += 1
            else:
                if stripped.startswith("```"):
                    blocks.append(
                        MermaidBlock(
                            file_path=file_path,
                            start_line=start_line,
                            index=index,
                            code="".join(block_lines),
                        )
                    )
                    in_block = False
                else:
                    block_lines.append(raw_line)

    if in_block:
        blocks.append(
            MermaidBlock(
                file_path=file_path,
                start_line=start_line,
                index=index + 1,
                code="".join(block_lines),
            )
        )
    return blocks


def detect_diagram_type(block: MermaidBlock) -> str | None:
    for raw_line in block.code.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("%%"):
            continue
        keyword = stripped.split()[0]
        if keyword in MERMAID_KEYWORDS:
            return keyword
        if keyword == "stateDiagram-v2":
            return "stateDiagram"
        break
    return None


def resolve_cli_command() -> Sequence[str] | None:
    env_cli = os.environ.get("MERMAID_CLI")
    if env_cli:
        parts = shlex.split(env_cli)
        if parts and shutil.which(parts[0]):
            return parts
    for candidate in ("mmdc",):
        resolved = shutil.which(candidate)
        if resolved:
            return [resolved]
    return None


def render_block(block: MermaidBlock, output_dir: Path, command: Sequence[str]) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = output_dir / f"{block.slug}.svg"

    with tempfile.NamedTemporaryFile("w", suffix=".mmd", delete=False, encoding="utf-8") as tmp_file:
        tmp_file.write(block.code)
        tmp_path = Path(tmp_file.name)

    try:
        subprocess.run(
            [*command, "-i", str(tmp_path), "-o", str(output_path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    finally:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="Repository root to scan for markdown files.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("docs/assets/diagrams"),
        help="Directory where rendered diagrams will be written.",
    )
    parser.add_argument(
        "--render",
        action="store_true",
        help="Attempt to render SVGs when a Mermaid CLI is available.",
    )
    args = parser.parse_args(argv)

    markdown_files = list(iter_markdown_files(args.root))
    blocks: List[MermaidBlock] = []
    for file_path in markdown_files:
        blocks.extend(extract_blocks(file_path))

    if not blocks:
        print("No Mermaid code blocks found.")
        return 0

    errors: List[str] = []
    for block in blocks:
        diagram_type = detect_diagram_type(block)
        if diagram_type is None:
            errors.append(
                f"{block.file_path}:{block.start_line}: Unable to determine diagram type."
            )
        else:
            block.diagram_type = diagram_type

    if errors:
        print("Mermaid validation failed:")
        for message in errors:
            print(f"  - {message}")
        return 1

    print(f"Validated {len(blocks)} Mermaid diagram(s).")

    if args.render:
        command = resolve_cli_command()
        if command is None:
            print(
                "Mermaid CLI not available (expected 'mmdc' or command specified via MERMAID_CLI). Skipping rendering."
            )
        else:
            for block in blocks:
                render_block(block, args.output, command)
            print(f"Rendered {len(blocks)} diagram(s) into {args.output}.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
