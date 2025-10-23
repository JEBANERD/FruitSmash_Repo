# Repository Manifest Guardrails

This directory tracks generated documentation about the repo file layout. To keep
ChatGPT inputs manageable, use `split_manifest.py` after regenerating
`repo_manifest.json`. It writes a paginated set of manifests under
`repo_manifest_pages/` plus `repo_manifest_index.json` that summarises the pages
and enforces guardrails (≤5,000 lines and ≤~2.5 MiB per file).

If additional generated docs are introduced, run or extend the script so they
are chunked under the same thresholds before uploading.
