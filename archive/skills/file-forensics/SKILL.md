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
- **"Every byte-sequence is present" is weaker than "every file is present".**
  Content-addressed coverage cannot see a missing file whose content is
  boilerplate: `.git/HEAD` is the same 24 bytes in every repository, so one copy
  anywhere satisfies the check for all of them. 94 repositories passed a
  "0 unplaced" source check while 87 of them could not be opened by git at all.
  For anything where *being at that path* is the point, verify the structure
  works — and remember that **empty directories are not carried by a file-level
  copy** (git will not open a repo whose `refs/` is missing).
- **A rescale defeats every content-addressed check, and more pixels is not
  more quality.** The same document photographed once and kept twice at
  800×1156 and 820×1156 differed in **10 pixels out of 950,320** — identical
  content, different bytes, invisible to any hash-based dedup. Which copy to
  keep was decided by the JPEG's own evidence, not by size: the *smaller*
  image carried `Adobe Photoshop CC`, 300 dpi, and quantization tables
  averaging 10.1/13.3, while the larger one had no EXIF, tables averaging
  23.1/34.7, and had been stretched horizontally. **Read the quantization
  tables and EXIF before ranking two encodings of one image.**
- **Finding those pairs needs two stages, and the first must not be a nested
  loop.** Perceptual hash (dHash/aHash) split into bands for candidate
  generation — 16 bands of 16 bits, so a pair within Hamming distance 12 is
  missed with probability ~1e-5 — then confirm each candidate by resizing to a
  common size and **counting pixels differing by more than 60**. Comparing
  every pair directly is 2×10⁸ comparisons at 20k images and never finishes.
- **Encryption defeats content-addressed comparison entirely.** Encrypted
  Office documents re-salt on every save, so the same plaintext yields
  different bytes every time: five files that were pairwise "different" by
  sha256 could only be ordered into a version chain after decrypting them. Any
  dedup or coverage check that works on hashes is blind to encrypted files —
  and so is the question "do we already hold this?".
- **A password may be recoverable from the correspondence that delivered the
  file.** Senders routinely mail the password separately ("PW is sent in a
  separate mail"); searching the mailbox for that follow-up opened five
  documents an archive had written off as unreadable. Before recording a file
  as permanently opaque, look for the message that carried its key.
- **A name that asserts a fact must be re-checked when the fact changes.** A
  file labelled "unreadable" that has since been opened is now lying, and the
  next reader believes it.
- **Unicode normalisation bites name *markers*, not just path comparisons.** A
  check that looks for a marker word inside a filename fails when the disk
  returns NFD and the source literal is NFC — but only for words containing a
  dakuten or other combining mark. A marker without one matches by luck, which
  is how such a check passes for years and then breaks the day the wording
  changes. Normalise both sides.
- **A ledger cannot see a renamed file it never had a row for.** Anything that
  was already in place before the bookkeeping began has no row; rename it and
  the ledger has nothing to rewrite, while any earlier inventory now points at
  a path that no longer exists. The file is alive and no record says so. When
  the question is "does this content still exist", the only instrument that
  answers it is a walk of the actual disk — index by size, hash the candidates.
  Ledgers record what happened; they do not describe what is.
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
- **`find … -type d -empty -delete` removes structurally-required empty
  directories.** git will not open a repository whose `refs/` is missing, and
  `refs/` is legitimately empty when all refs live in `packed-refs`. Cleaning up
  empty directories immediately after restoring them undid the repair and turned
  12 repositories red again.
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
