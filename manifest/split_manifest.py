#!/usr/bin/env python3
"""Split generated repository manifests into pagination-friendly chunks.

This script enforces guardrails so each generated documentation file stays
within ChatGPT-friendly limits (roughly <=5k lines or <=~2.5MB). It reads the
existing ``repo_manifest.json`` and emits a paginated set of JSON files along
with an index that describes the pages.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import List

MAX_LINES = 5000
# 2.5 MiB guardrail (roughly 2–3 MB window mentioned in requirements).
MAX_BYTES = int(2.5 * 1024 * 1024)
PAGE_DIRNAME = "repo_manifest_pages"
PAGE_FILENAME_TEMPLATE = "repo_manifest_page_{page}.json"
INDEX_FILENAME = "repo_manifest_index.json"
SOURCE_MANIFEST = "repo_manifest.json"


@dataclass
class PageBuffer:
    """Helper to track in-progress pagination state."""

    start_index: int
    entries: List[dict]

    @property
    def end_index(self) -> int:
        return self.start_index + len(self.entries) - 1

    def as_document(self, base_payload: dict, page: int, total_pages: int) -> dict:
        doc = {
            **base_payload,
            "page": page,
            "total_pages": total_pages,
            "entry_start_index": self.start_index + 1,
            "entry_end_index": self.end_index + 1,
            "files": self.entries,
        }
        return doc


def load_manifest(manifest_path: Path) -> dict:
    if not manifest_path.exists():
        raise FileNotFoundError(f"Manifest not found: {manifest_path}")
    with manifest_path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if "files" not in data or not isinstance(data["files"], list):
        raise ValueError("Manifest is missing expected 'files' list")
    return data


def measure_document(doc: dict) -> tuple[int, int, str]:
    text = json.dumps(doc, indent=2, ensure_ascii=False)
    # Add trailing newline for POSIX-friendly files.
    text_with_newline = text + "\n"
    line_count = text_with_newline.count("\n")
    byte_count = len(text_with_newline.encode("utf-8"))
    return line_count, byte_count, text_with_newline


def split_entries(manifest: dict) -> list[PageBuffer]:
    files = manifest.get("files", [])
    base_payload = {
        key: manifest[key]
        for key in ("repo_name", "generated_at", "total_files")
        if key in manifest
    }
    base_payload["source_manifest"] = SOURCE_MANIFEST

    buffers: list[PageBuffer] = []
    current = PageBuffer(start_index=0, entries=[])

    for idx, entry in enumerate(files):
        if not current.entries:
            current.start_index = idx

        candidate_entries = current.entries + [entry]
        preview_doc = {
            **base_payload,
            "page": len(buffers) + 1,
            "total_pages": 0,
            "entry_start_index": current.start_index + 1,
            "entry_end_index": idx + 1,
            "files": candidate_entries,
        }
        lines, bytes_len, _ = measure_document(preview_doc)
        exceeds_limits = lines > MAX_LINES or bytes_len > MAX_BYTES

        if current.entries and exceeds_limits:
            buffers.append(current)
            current = PageBuffer(start_index=idx, entries=[entry])
        else:
            current.entries = candidate_entries

    if current.entries:
        buffers.append(current)

    return buffers


def write_pages(manifest: dict, buffers: list[PageBuffer], output_dir: Path) -> list[dict]:
    base_payload = {
        key: manifest[key]
        for key in ("repo_name", "generated_at", "total_files")
        if key in manifest
    }
    base_payload["source_manifest"] = SOURCE_MANIFEST

    output_dir.mkdir(parents=True, exist_ok=True)
    page_summaries: list[dict] = []

    total_pages = len(buffers)
    for page_number, buffer in enumerate(buffers, start=1):
        doc = buffer.as_document(base_payload, page_number, total_pages)
        lines, bytes_len, text = measure_document(doc)
        if lines > MAX_LINES or bytes_len > MAX_BYTES:
            raise ValueError(
                f"Page {page_number} exceeds guardrails (lines={lines}, bytes={bytes_len})"
            )
        filename = PAGE_FILENAME_TEMPLATE.format(page=page_number)
        path = output_dir / filename
        path.write_text(text, encoding="utf-8")
        page_summaries.append(
            {
                "page": page_number,
                "path": str(path.relative_to(output_dir.parent)),
                "entries": len(buffer.entries),
                "entry_start_index": buffer.start_index + 1,
                "entry_end_index": buffer.end_index + 1,
                "lines": lines,
                "bytes": bytes_len,
            }
        )

    return page_summaries


def write_index(manifest: dict, page_summaries: list[dict], index_path: Path) -> None:
    index_doc = {
        key: manifest[key]
        for key in ("repo_name", "generated_at", "total_files")
        if key in manifest
    }
    index_doc.update(
        {
            "source_manifest": SOURCE_MANIFEST,
            "page_count": len(page_summaries),
            "thresholds": {"max_lines": MAX_LINES, "max_bytes": MAX_BYTES},
            "pages": page_summaries,
        }
    )
    index_path.write_text(
        json.dumps(index_doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    repo_root = Path(__file__).resolve().parent
    manifest_path = repo_root / SOURCE_MANIFEST
    manifest = load_manifest(manifest_path)

    buffers = split_entries(manifest)
    output_dir = repo_root / PAGE_DIRNAME
    page_summaries = write_pages(manifest, buffers, output_dir)
    index_path = repo_root / INDEX_FILENAME
    write_index(manifest, page_summaries, index_path)


if __name__ == "__main__":
    main()
