---
name: archive-ingest
description: Use when moving files INTO the curated archive on pandanas (`/volume1/PandanasShared`, mounted at `~/nas/pandanas` on studio) — sorting a source tree, clearing `~/Downloads`, absorbing a new disk or sync folder, unpacking archives, renaming/classifying documents, deduplicating, demoting old versions, or deciding whether a source can finally be deleted. Also triggers when asked "整理到 NAS", "这些文件怎么归档", "新的源怎么处理", or when about to run `mv`/`rm`/`cp` inside that archive. The archive keeps append-only ledgers and 40 invariants; bypassing them silently breaks the only thing that can answer "what did we lose".
---

# Getting files into the pandanas archive

There is a curated archive at `/volume1/PandanasShared` on **pandanas**
(`lihao@192.168.50.26`; SMB-mounted on studio at `~/nas/pandanas`). Everything
that flows into it comes from a **source** — a sync folder, an external disk, a
rescue mirror, a Downloads directory. Sources keep producing, and new ones
appear. This skill is the protocol for that flow.

**The authority is `INGEST.md` in the archive root.** Read it before doing
anything non-trivial — it carries the current entry points and the traps that
have actually bitten. This skill is the map; that file is the terrain.

```bash
ssh lihao@192.168.50.26 'cat /volume1/PandanasShared/INGEST.md'
```

## The one invariant everything else serves

Every file in a registered source is in exactly one of three states:

| state | ledger | meaning |
|---|---|---|
| placed | `PLACED.tsv` | it is in the archive |
| pre-existing | `ARCHIVE.pre` | it was in the archive before the curation began |
| excluded | `EXCLUSION-LIST.tsv` | deliberately not placed, **with a reason and measured evidence** |

Anything in none of them is **未落位** (unplaced). A source with unplaced files
cannot be deleted. That is the whole point: the archive can answer "what did we
lose" only while that invariant holds.

```bash
python3 .staging/srccover.py            # all registered sources, one report
python3 .staging/srccover.py stsync     # just one
```

## Sources are registered, not assumed

`SOURCES.tsv` in the archive root is the registry. **A new source gets a row
before it gets touched.** Columns: id / state / kind / place / collecting host /
exclusion rules / ledger path / verification mode / note.

```bash
# 1. add the row to SOURCES.tsv
# 2. build its ledger — ON THE COLLECTING HOST named in the row
python3 .staging/srcledger.py <id> --apply
# 3. diff it against the archive
python3 .staging/srccover.py <id>
# 4. work the unplaced list down to zero
# 5. only then set state=retired and delete the source
```

`srcledger.py` refuses to run on the wrong host — a ledger built where the
source isn't mounted would be silently empty, and an empty ledger looks exactly
like a fully-absorbed source.

**Exclusion rules in the registry are only for what the platform itself
generates** (`@eaDir`, `#recycle`, `._*`, `.DS_Store`, `Thumbs.db`, Office's
`.~*` lock files). A real file is never dropped by a registry rule — that
requires an `EXCLUSION-LIST.tsv` row with evidence.

## Writes go through five entry points. Never around them.

| tool | does | enforces |
|---|---|---|
| `relocate.py` | move / rename | rewrites the PLACED row (appending creates ghost paths), logs to RENAME-LOG, refuses to demote a superseder |
| `supersede.py` | demote an older version | moves to `superseded/`, logs the reason, refuses chain-breaking demotions |
| `remove.py` | delete | refuses to delete a superseder; **re-measures the survivor at the moment of deletion**; logs to DELETION-LOG; drops the PLACED row |
| `unpack.py` / `unpackx.py` | open a zip / rar / 7z | extracts only members not already bare; registers what it extracts; **prints everything it skipped** |
| `annul.py` | retract a demotion | marks the SUPERSEDE-LOG row with `#`; history is never erased |

A bare `mv` / `rm` / `cp` inside the archive desynchronises the ledgers from
reality, and the ledgers are the only instrument that can say what was lost.

Two repair tools exist for when they do drift: `plclean.py` (drop PLACED rows
whose file is gone *and* which have a DELETION-LOG record) and `exclzip.py`
(absorb source-side copies that became unplaced because the archive-side archive
was removed).

## Getting one file in — eight stages

1. **Collect** — build the source ledger. The source is read-only, always.
2. **Diff** — produce the unplaced list.
3. **Triage** — duplicate / older version / excludable / unsorted.
4. **Read** — *open the file*. See the sibling `file-forensics` skill.
5. **Name** — entity + category + description + date. The date is the date
   **inside** the document; mtime is the backup date and a `_YYYYMMDD_HHMMSS`
   suffix is an export timestamp (measured 1.5–2.5 years off).
6. **Place** — `relocate.py`. Inside a bundle directory, original names stay.
7. **Verify** — `python3 .staging/check.py` (T1–T40, 12–25 min).
   **Do not mutate the archive while it runs** — it produces false failures.
8. **Record** — write what you *learned* into the entity's README. Counts are
   fixed by `fixcount.py` / `catcount.py` / `prosecount.py` / `roster.py` /
   `mdsync.py`, not by hand.

### Duplicates and versions — the standing rule

- byte-identical → keep one
- different versions → **keep the newest, demote the rest to `superseded/`**
- different *roles* (a curated document vs. the same bytes inside a submitted
  package) → keep both, and say why in the README

`superseded/` is not a delete queue. Files there were sometimes the ones
actually submitted.

### Archives (zip / rar / 7z)

**Unpack them; don't keep the container.** Three recorded exceptions, each
written into the root README with its reason:

1. it contains a private key (unpacking scatters keys through the archive)
2. unpacking yields tens of thousands of members
3. it *is* the distribution (a third-party app's dmg/7z, not a wrapper)

`unpack.py --tree` restores members at their in-archive relative paths (for
bundles); flat mode with a prefix is for the curated layer. `--skip-junk` drops
platform noise, `--skip-name` drops explicitly named members — both print what
they dropped, and both must be justified in the deletion reason.

## Red lines

- **Never delete from a source** until `srccover.py` reports 0 unplaced for it,
  `check.py` passes, and the archive-side copy was re-measured **at deletion
  time** — not read off an earlier report. State moves between the report and
  the delete; a run that reported 81 duplicate pairs measured 68 an hour later.
- **Never decide from a filename.** A file named `給与所得の源泉徴収票` held a
  corporate tax filing; one named `部门活动策划表` held a price comparison of
  five restaurants; one named `署名済` was the copy *missing* a seal.
- **Never mutate during `check.py`.**
- **Never let a private key land outside `keys/`**, and keys are mode 600.
- **Third-party personal data** (other people's IDs, grades, customer tables,
  applicant CVs) gets flagged in the root README's §六, not quietly filed.
