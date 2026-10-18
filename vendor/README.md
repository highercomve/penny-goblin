# Oriel build snapshot

This source-only snapshot captures the Oriel package used by Penny Goblin on
2026-10-18, based on upstream `7e2276132b401a440984881cd6ac4e031ac56b01` with unreleased renderer changes.
It is vendored so a clean checkout builds without a developer's local path or
private token. Upstream: https://github.com/highercomve/Oriel.

`oriel/SNAPSHOT.json` records the file SHA-256s. Oriel's LICENSE, NOTICE and
third-party licenses are retained. This does not publish or modify the upstream
working tree. Refresh deliberately from a tested Oriel version, regenerate the
manifest, and run both renderers and Android CI before merging.
