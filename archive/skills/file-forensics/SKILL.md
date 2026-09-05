---
name: file-forensics
description: Use before concluding that two files are the same, that one is a duplicate or a thumbnail or a lower-quality copy, that one version is newer or better, or that a sweep found everything. Covers comparing images, PDFs, Office documents, 3D/design binaries and archives; reading a document's real date; and the ways a measurement silently fails so that its output looks like data. Triggers on "是不是重复", "哪个版本更好/更新", "这两个一样吗", dedup passes, "keep the best copy", and any decision to delete one of two similar files.
---

# Deciding whether two files are the same — and which one to keep

The failure that matters here is not being wrong. It is being wrong **in a way
that looks exactly like being right**: a measuring instrument that breaks
produces output shaped like data. Every rule below came from an instrument that
broke on real files.

## The first rule

**Every measurement gets a cross-check that does not share its failure mode.**
A count that must match, a total that must add up, a second signal from a
different source. "It printed something" is not evidence that it ran.

## Comparing content

| question | wrong instrument | right instrument |
|---|---|---|
| same file? | same name, or same size | **hash the whole file** (sha256 / CRC-32) |
| same picture? | mean absolute difference with a threshold | **count the pixels differing by more than 60**; MAD hides a few substituted characters |
| same document? | first N bytes, or rendered pixels | **diff the text layer**; two versions differing by one word render nearly identically |
| same PDF? | file size | page count + **`pdfimages -list`**: embedded image dimensions, depth, and count, row by row |
| which is higher quality? | the larger file | measure it — 755.6 MB and 29.8 MB held the same 887 pages with **zero** embedded images either side (duplicated font resources); 61.5 MB and 73.5 MB held 115 byte-identical images |
| same spreadsheet? | `workbook.xml` | hash `worksheets/` + `sharedStrings.xml` |
| is the small one a thumbnail? | assume | scale both to a common size and measure — a 3,650 B / 160×120 "thumbnail" turned out to be a **different photograph** (MAD 76, 66% of pixels differing by >60) |
| rotated / downscaled copy? | direct comparison (shapes differ) | try all four rotations, resize to a common size; a genuine match reads MAD 1–2 with **zero** pixels differing by >60 |
| same archive? | member names | member CRC-32 + size, or extract and hash |

Diverging within the first ~80 bytes of two same-format binaries (`.max`,
`.psd`, `.ai`) means they are genuinely different saves, not a re-encode.
Re-saving in 3ds Max / Photoshop appends a preview, so the **later** copy is
usually slightly larger — but confirm rather than assume the direction.

## Reading a document's real date

- **mtime is the backup date.** Whole trees carry one identical mtime.
- A `_YYYYMMDD_HHMMSS` suffix in a filename is an **export timestamp**, measured
  1.5–2.5 years away from the document's own date.
- Office: `docProps/core.xml` → `dcterms:created` / `dcterms:modified`.
- Illustrator / PDF: the XMP packet → `xmp:CreateDate` / `xmp:ModifyDate` /
  `xmp:CreatorTool`. This resolves version chains exactly — six `.ai` files
  saved 19:13–19:21, the same six saved 20:27–20:38, and three of them saved
  again five days later under a newer Illustrator, is three generations, read
  straight off the metadata.
- Photos: EXIF `DateTimeOriginal`. When a copy exists only inside a zip, the
  archive's internal timestamps may be **the only surviving record** of the real
  date — copy it out before deleting the container.
- `xmpMM:OriginalDocumentID` in an Illustrator file is often the **template's**
  UUID, not this document's provenance. Do not treat it as a fingerprint.

## Ways a sweep reports clean and is not

- **Identity can live on the directory, not the file** — `李好25在留カード/正面.jpg`
  does not match a filename filter for the ID type. Match the whole path.
- **An index may store a different form of the name** — a slug, a romanisation.
  Query every form the index holds.
- **Mixed hash types match nothing and look like "not a duplicate"** — md5 from
  one report against sha256 from another. Prefixes of different hash functions
  are indistinguishable by eye.
- **A deletion sweep is finished when a differently-shaped search finds nothing
  left** — a different matcher, a different field, run afterwards. The delete
  script and its verification must not share a way of being wrong.

## Ways the tooling lies

- **`pdftotext` with no CJK language pack returns empty, silently.** Two empty
  extractions compare equal. Check that the tool can read the language before
  trusting "the text is identical".
- **`sort -u` / `uniq` collapse distinct multi-byte strings under a UTF-8
  locale.** Export `LC_ALL=C` for the *whole* pipeline, not just one command.
- **The same directory yields different path strings on different hosts.**
  Linux returns the bytes as stored (NFC); macOS over SMB normalises to NFD. A
  ledger written on one and compared on the other reports *every* entry missing.
  Normalise (`unicodedata.normalize("NFC", …)`) before comparing paths.
- **Two file counts taken with different conventions are not comparable.** A
  ledger that filtered AppleDouble files at build time, checked against a walk
  that filtered at compare time, differs by 403,000 entries with nothing having
  changed. Decide where the filter lives and apply it on both sides — and skip
  broken symlinks identically, since one side may count them and the other not.
- **`ps w` truncates.** Use `/proc/*/cmdline` to decide whether a process lives.
- **`print` to a pipe is block-buffered** — a running job looks stalled. Use
  `flush=True`, and give long scans progress output.
- **`ssh` inside a loop drains the loop's stdin**: one iteration runs and the
  script reports zero failures. Use `ssh -n`, read the list on a non-standard fd.
- **macOS has no `timeout`** — a dead prober and an unreachable host produce
  identical output.
- **`du` counts reflinks** — it can report 2.29 TB where `df` says 1.4 TB.
- **`@eaDir` grows when writing over SMB** and breaks checks that enumerate a
  single directory.
- **A zip member can be CRC-corrupt**: it cannot be extracted at all, so its
  survival cannot be confirmed from the archive. Check whether an intact bare
  copy exists (matching size, correct magic bytes) before writing either off.
- **Filename encoding**: a zip with flag `0x800` already decoded its names as
  UTF-8 — decoding again as cp437 mangles them (`李好` → `鏉庡ソ`). Without the
  flag, try **utf-8 before gbk**: UTF-8 bytes decode "successfully" as GBK and
  produce mojibake, while real GBK almost never passes UTF-8 validation.

## Predicting a saving

When estimating how much a change will save, **split the estimate into parts
that can each be measured separately, and require their sum to match the
measured total**. That identity is the check. Single whole-number predictions
were wrong five times out of six; the one that survived was the one built as
16 + 15 + 62 = 93.
