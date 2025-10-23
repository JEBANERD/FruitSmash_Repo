#!/usr/bin/env python3
"""Validate Markdown links and anchors inside docs/."""
from __future__ import annotations

import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple

_LINK_RE = re.compile(r"(?<!\\)!?\[(?P<label>[^\]]+)\]\((?P<link>[^)]+)\)")
_HEADING_RE = re.compile(r"^(?P<level>#{1,6})\s+(?P<title>.+?)\s*$")
_ANCHOR_TAG_RE = re.compile(r"<a\s+(?:name|id)=\"(?P<id>[^\"]+)\"", re.IGNORECASE)


@dataclass
class LinkIssue:
    source: Path
    link: str
    reason: str


def _slugify(title: str) -> str:
    slug = title.strip().lower()
    slug = re.sub(r"[`~!@#$%^&*()=+[{]}\\|;:'\",<>./?]", "", slug)
    slug = re.sub(r"\s+", "-", slug)
    slug = re.sub(r"-+", "-", slug)
    return slug.strip("-")


def _collect_anchors(doc_path: Path) -> Set[str]:
    anchors: Set[str] = set()
    counts: Dict[str, int] = defaultdict(int)
    text = doc_path.read_text(encoding="utf-8")

    for line in text.splitlines():
        heading_match = _HEADING_RE.match(line)
        if heading_match:
            base = _slugify(heading_match.group("title"))
            count = counts[base]
            counts[base] += 1
            anchor = base if count == 0 else f"{base}-{count}"
            if anchor:
                anchors.add(anchor)
            continue

        for tag_match in _ANCHOR_TAG_RE.finditer(line):
            anchors.add(tag_match.group("id"))

    return anchors


def _is_external(link: str) -> bool:
    return link.startswith("http://") or link.startswith("https://") or link.startswith("mailto:") or link.startswith("tel:")


def _check_links(repo_root: Path, docs: Iterable[Path]) -> Tuple[List[LinkIssue], int]:
    anchors_by_doc: Dict[Path, Set[str]] = {}
    for doc in docs:
        anchors_by_doc[doc] = _collect_anchors(doc)

    issues: List[LinkIssue] = []
    total_links = 0

    for doc in docs:
        text = doc.read_text(encoding="utf-8")
        for match in _LINK_RE.finditer(text):
            link = match.group("link").strip()
            label = match.group("label")
            if label.startswith("!"):
                continue
            if not link or _is_external(link):
                continue

            total_links += 1

            if link.startswith("#"):
                anchor = link[1:]
                if anchor and anchor not in anchors_by_doc.get(doc, set()):
                    issues.append(LinkIssue(doc, link, "missing anchor in same file"))
                continue

            if "#" in link:
                path_part, anchor = link.split("#", 1)
            else:
                path_part, anchor = link, None

            target = (doc.parent / path_part).resolve()
            try:
                target.relative_to(repo_root)
            except ValueError:
                issues.append(LinkIssue(doc, link, "points outside repository"))
                continue

            if not target.exists():
                issues.append(LinkIssue(doc, link, "target does not exist"))
                continue

            if anchor:
                if target.suffix.lower() != ".md":
                    issues.append(LinkIssue(doc, link, "anchor specified on non-markdown target"))
                    continue
                anchor_set = anchors_by_doc.get(target)
                if anchor_set is None:
                    anchor_set = _collect_anchors(target)
                    anchors_by_doc[target] = anchor_set
                if anchor not in anchor_set:
                    issues.append(LinkIssue(doc, link, "anchor missing in target file"))

    return issues, total_links


def main(argv: List[str]) -> int:
    repo_root = Path(__file__).resolve().parents[1]
    doc_root = Path(argv[1]) if len(argv) > 1 else Path("docs")
    doc_root = (doc_root if doc_root.is_absolute() else (repo_root / doc_root)).resolve()

    if not doc_root.exists():
        print(f"docs directory not found: {doc_root}")
        return 1

    docs = sorted(doc_root.rglob("*.md"))
    if not docs:
        print(f"No markdown files found under {doc_root}")
        return 0

    issues, total_links = _check_links(repo_root, docs)

    print(f"Scanned {len(docs)} Markdown files with {total_links} links.")
    if not issues:
        print("No broken links or anchors detected.")
        return 0

    print("Broken links/anchors:")
    for issue in issues:
        rel_source = issue.source.relative_to(repo_root)
        print(f"- {rel_source}: '{issue.link}' -> {issue.reason}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
