# archive

Two skills for the curated archive on **pandanas** (`/volume1/PandanasShared`,
SMB-mounted on studio at `~/nas/pandanas`).

| skill | when it fires |
|---|---|
| `archive-ingest` | moving files *into* the archive — sorting a source, clearing Downloads, absorbing a new disk, unpacking, renaming, deduplicating, deciding a source can be deleted |
| `file-forensics` | before concluding two files are the same, or that one is a duplicate / thumbnail / older version. Deliberately project-agnostic |

A PreToolUse hook backs the first skill: a bare `mv` / `rm` / `cp` / `rsync`
aimed at the archive, or an `rm` aimed at a registered source, gets a one-line
steer toward the entry point that keeps the ledgers in step. It never blocks —
a false positive costs a sentence, a false negative costs a ledger that no
longer matches the disk.

## Why

Sources keep producing, and new sources appear. The archive answers "what did we
lose" only while one invariant holds: **every file in a registered source is
either placed, pre-existing, or excluded with measured evidence.** Everything in
`archive-ingest` exists to keep that true — the source registry (`SOURCES.tsv`),
one coverage check (`srccover.py`) instead of one per source, and five write
entry points that keep the ledgers in step with the disk.

`file-forensics` is the other half: every rule in it came from an instrument
that broke on real files and produced output shaped like data.

The operational authority is `INGEST.md` in the archive root; the current state
is its `README.md`. These skills are the map, not the terrain.
