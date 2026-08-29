# enexodus — working notes

Internal context for anyone (human or agent) changing this code. The user-facing docs are
`README.md` and `--help`; this file is the *why*, plus the traps.

## What it is

A Swift Package Manager executable converting Evernote ENEX exports to a folder-per-notebook
Markdown vault. Built against a WP-1..WP-6 plan. Phase 1 (convert + verify) is done; Phase 2
(OSS polish, CI matrix, prebuilt binaries, config file) is deliberately not started.

Dependencies: `swift-argument-parser` only. No network at runtime. MD5 is hand-written because
CryptoKit is Apple-only and swift-crypto was not approved.

## Layout

```
Sources/enexodus/
  main.swift            root command
  CLI/                  ConvertCommand, VerifyCommand
  ENEX/                 ENEXParser (streaming), Note, Resource, MD5
  ENML/                 ENMLDocument (parse), MarkdownRenderer (core), HTMLFallback
  Output/               VaultWriter, Frontmatter, Slug
  Verify/               VerificationReport
```

`MarkdownRenderer.swift` is where the complexity lives. Read `RenderState.Fragment` first — the
whole block model turns on it.

## Invariants — do not break these

1. **Losslessness.** For every note, the text content of the input ENML must appear in the
   output, in order, modulo whitespace. This is the non-negotiable. Anything that cannot be
   mapped goes to `HTMLFallback`, never gets approximated or dropped. The test carries a
   negative control proving the check can fail; keep it.
2. **Determinism.** No run timestamps, no wall-clock, no hash-order iteration in output. A
   second conversion into the same vault must produce byte-identical files. `Date.now`,
   `Math.random`-equivalents and unordered dictionary iteration in emitters are all bugs.
3. **Two independent count paths in `verify`.** The ENEX side re-parses; the vault side reads
   only files on disk. Never make one derive from the other, or the check becomes a tautology.
   They share only `VaultWriter.locations` and the two marker constants — that shared surface is
   the known weak point.
4. **Streaming.** Peak memory is bounded by the largest single note, not the file. Measured
   ~16 MB for 72/290/580 MB inputs. Anything that accumulates across notes is a regression.
5. **No real note content in the repo.** Fixtures are synthetic. This applies to test data,
   commit messages, and any report committed here.
6. **Filenames cannot escape their notebook directory.** `Slug.make` is the only thing standing
   between a hostile title and the filesystem. `hostile.enex` covers it; keep it covered.

## Traps discovered the hard way

- **`NSXMLParser` is not reentrant.** Rendering a note from inside the ENEX parser's delegate
  callback raises `NSInternalInconsistencyException`. The guard is per-thread, so
  `ENMLParseWorker` runs ENML parses on one dedicated long-lived thread. This is a workaround
  for a genuine conflict in the plan's architecture; the alternative fixes are buffering every
  note (loses the streaming profile) or hand-writing an ENML tokenizer (larger change). Flagged,
  not resolved.
- **`autoreleasepool` matters here.** `FileHandle.read(upToCount:)` returns autoreleased
  `NSData`; without a pool drained per iteration, peak RSS tracked file size 1:1 (290 MB file →
  296 MB resident) and the streaming design was a fiction. Same for the per-note handler. This
  was found by *measuring*, not by reading the code — measure again after touching either loop.
- **`XMLParser` silently drops U+FEFF** from character data anywhere, not just at the start. It
  is zero-width so nothing visible is lost, but it is a real gap between source bytes and output.
  Not worked around.
- **The Evernote DTD must never be fetched.** `&nbsp;` and friends are declared there, so
  libxml2 rejects them. `ENEXParser.requiresEntityNormalization` does a streaming pre-scan and
  only then falls back to an in-memory normalized parse. The pre-scan exists because retrying
  mid-parse would hand `onNote` the leading notes twice.
- **Evernote has two unrelated checklist encodings.** `<en-todo/>`, and
  `<ul style="--en-todo:true">` with `--en-checked:true|false` on items. The second is ~5x more
  common in real exports. Missing it silently turns every checkbox into a plain bullet.
- **`<div>` is a line, not a paragraph.** Getting this backwards double-spaces every note and
  discards the author's real blank lines. This was the single biggest output-quality bug.

## Testing

`swift test` — 105 tests. Golden trees in `Tests/enexodusTests/Fixtures/expected/` are compared
byte-for-byte, so any intentional rendering change means regenerating them:

```bash
swift build && ./.build/debug/enexodus convert -q -i Tests/enexodusTests/Fixtures -o /tmp/regen
diff -ru Tests/enexodusTests/Fixtures/expected /tmp/regen   # REVIEW EVERY DIFF BY EYE
rm -rf Tests/enexodusTests/Fixtures/expected && cp -R /tmp/regen Tests/enexodusTests/Fixtures/expected
```

Never regenerate goldens without reading the diff. They are the record of intended behaviour;
blind regeneration turns them into a record of current behaviour, which is worthless.

## Unverified

**Linux has never been built or tested** — no container runtime was available. The audit says it
should work (no Darwin-only APIs, `XMLParser` behind `#if canImport(FoundationXML)`, in-package
MD5). The two open risks are SwiftPM testing an *executable* target on Linux, and libxml2
version differences in entity handling. If executable-target testing fails there, the fix is
splitting out a library target, which changes the layout in the plan.

## Open items

- `Cordia New` and other non-standard fonts used for code are not detected — only a closed list
  of known monospace families is. Widening it risks turning prose into code blocks.
- Notebook *stacks* are unrecoverable; ENEX does not record them.
- Naming: the plan calls the product `enexodus`; the containing directory is `exenodus`.
