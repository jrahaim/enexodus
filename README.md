# enexodus

Converts Evernote ENEX exports into a folder-per-notebook Markdown archive, for reading in
Obsidian (or any Markdown editor) and keeping in a git repo.

> **Status: Phase 1.** Built against the WP-1..WP-6 plan. The public-release polish
> (configurable layout, CI matrix, prebuilt binaries) is Phase 2 and deliberately not started.

## Exporting from Evernote

**Export one notebook at a time, and name each file after its notebook.**

This matters more than any converter setting, and it cannot be fixed afterwards. **ENEX has no
notebook field** — the format simply does not record which notebook a note came from. The
filename is the only surviving evidence, which is why enexodus treats it as the notebook name.

In Evernote: right-click a notebook → *Export Notes* → save as `<Notebook Name>.enex`. Repeat
per notebook.

What survives the export, and what does not:

| | survives? |
| --- | --- |
| Note title, body, dates, attachments | yes |
| Tags | yes (`tags:` in frontmatter) |
| Source URL, author | yes, when Evernote recorded them |
| **Notebook membership** | **only as the filename** |
| **Stacks** (notebook groups) | **no** — nothing in ENEX records them |

So a single "export everything" into one `.enex` produces one giant folder, and the notebook
structure is gone for good. If that has already happened, re-export per notebook **while you
still have Evernote access** — no tool can reconstruct it later. If you want stacks in the
output, name the files `Stack - Notebook.enex` and split them afterwards.

Evernote caps an export at 100 notes per file and suffixes the overflow, so a large notebook
arrives as `My Notes.enex` + `My Notes (1).enex` + `My Notes (2).enex`. That is expected —
enexodus merges them back into one folder. Only a trailing parenthesised integer is folded, so
a notebook genuinely named `Recipes (old)` is left alone.

## Usage

```bash
swift build -c release

# a whole export directory
.build/release/enexodus convert --input ~/EvernoteExport --output ~/Vault

# a single notebook
.build/release/enexodus convert --input ~/EvernoteExport/Recipes.enex --output ~/Vault

# several files at once (--input repeats)
.build/release/enexodus convert \
  --input "~/EvernoteExport/My Notes.enex" \
  --input "~/EvernoteExport/My Notes (1).enex" \
  --output ~/Vault

.build/release/enexodus verify --input ~/EvernoteExport --output ~/Vault
```

`--input` (`-i`) is a `.enex` file or a directory of them, and may be repeated. `--output`
(`-o`) is the vault directory; every notebook becomes a subfolder of it, so converting several
exports into the same vault is the normal case.

| Flag | Command | Meaning |
| --- | --- | --- |
| `--clean` | convert | Delete each target notebook directory before writing it |
| `--spacing faithful\|tight` | convert | Blank-line spacer policy (default `tight`) |
| `--quiet`, `-q` | convert | Print only the summary |
| `--json` | verify | Emit the report as JSON |

`verify` exits non-zero on any mismatch, which makes it usable as a CI or pre-commit gate.

## Output layout

```
<output>/
  <Notebook Name>/
    <Note Title>.md
    _attachments/
      <resource files>
```

Each note gets YAML frontmatter — `title`, `created`, `updated`, `tags`, `source-url` when
present, `notebook`, `enex-source` — followed by the rendered body.

Written files also carry the note's own timestamps: modification date from `updated`, and on
macOS creation date from `created`. Without this a whole vault sorts as a single day in Finder,
`ls -lt` and Obsidian. Taking them from the note rather than the clock also means a re-run
reproduces them exactly. Linux has no settable birth time, so only the modification date is
applied there. Attachments inherit their note's dates, since ENEX resources carry none.

Attachments keep their original `<file-name>` when the export has one, otherwise they are named
from the first 8 hex digits of the resource MD5 plus an extension derived from the MIME type.
Identical bytes are written once and linked from every note that references them. Resources that
no `<en-media>` refers to are still written, and `verify` reports them rather than dropping them.

Filenames are derived from note titles: NFC-normalized, path separators and control characters
replaced, trimmed to 120 characters, and de-duplicated with `-2`, `-3` suffixes. A title cannot
escape its notebook directory — `../../etc/passwd` becomes `etc-passwd.md`.

## Design

**Evernote's `<div>` is a line, not a paragraph.** Evernote writes one `<div>` per visual line
and an explicit `<div><br/></div>` where the author wanted a blank one. Treating every div as a
paragraph double-spaces the whole archive and destroys the author's real structure, so
consecutive divs become consecutive lines and only spacer divs break a paragraph.

Related consequences of that model:

- Lines within a block are joined with a plain newline, which Obsidian renders as a line break.
  Strict CommonMark treats it as a soft break; the Phase 2 output-flavour toggle is where that
  becomes selectable.
- **Checklists.** Evernote has two unrelated encodings and both appear in real exports: the old
  `<en-todo/>` element, and `<ul style="--en-todo:true">` whose items carry
  `--en-checked:true|false`. In one real corpus the second was five times more common (76 items
  against 14). Both become GFM task lists (`- [ ]` / `- [x]`), including when nested. An
  `<en-todo>` leading *any* block container counts, not only one inside `<li>`.
  Checked items are not struck through: the strikethrough is Evernote's UI styling its checked
  state, not content.
- **Code blocks.** A container whose text is entirely in a monospace font becomes a fenced code
  block, and consecutive such lines fuse into one fence. Older exports have no
  `--en-codeblock` marker — in one real 255-note export only 2 notes used it, versus 37 using
  monospace fonts. A monospace run *within* a line becomes an inline code span instead.
- **Spacing (default `tight`).** Drops blank lines in notes that put one after *every* line — a
  separator that appears everywhere separates nothing, so it is a typing habit rather than
  structure. Notes that use blank lines selectively are left untouched, and a run of two or more
  spacers always survives as one blank line. On a real 16-note notebook it changed 3 notes and
  left 13 alone. `--spacing faithful` reproduces every spacer instead.
- U+00A0 and friends are normalized to ordinary spaces. Evernote uses non-breaking space as its
  everyday word separator — 13,727 of them in one real 115 KB notebook, a quarter of all
  characters — which silently breaks Obsidian search and `grep`. Whitespace is outside the
  losslessness contract, so this is safe.

**Lossless over pretty.** ENML that does not map cleanly onto Markdown is emitted as sanitized
inline HTML rather than approximated or dropped. Every such block is preceded by
`<!-- enexodus:html-fallback reason="..." -->`, and an `<en-media>` whose hash matches no
resource leaves `<!-- enexodus:missing-resource ... -->` where it stood. Both markers are
counted by `verify`, so nothing is lost silently. A note whose ENML will not parse at all is
written as sanitized raw HTML rather than skipped.

Sanitization removes `<script>`, `<iframe>`, `on*` handlers and `javascript:` URLs. It removes
nothing else — structure and text are kept intact.

**Deterministic.** Output depends only on the ENEX content and note order; there are no run
timestamps. Converting twice produces byte-identical files, so a re-run is an empty `git diff`.

**Independent verification.** `verify` computes each count twice — once by re-parsing the ENEX,
once by reading only the files on disk — and compares. Neither number is derived from the other,
so a bug in the writer cannot make the check agree with itself.

**Streaming.** Notes are parsed and written one at a time. Measured peak RSS is ~16 MB whether
the input is 72 MB, 290 MB, or 580 MB.

No network access at runtime; the Evernote DTD is never fetched. The only dependency is
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache-2.0).

**Known omission:** Foundation's `XMLParser` drops U+FEFF (zero-width no-break space) from
character data wherever it appears. Nothing visible is lost, but a stray BOM pasted mid-note
will not survive into the Markdown.

## Requirements

macOS 14+ or Linux. Swift 6.0+.

> Linux support is by source audit, not a passing build: no Darwin-only APIs are used,
> `XMLParser` is behind `#if canImport(FoundationXML)`, and MD5 is implemented in-package
> because CryptoKit is Apple-only. It has **not** been compiled or tested on Linux. The two
> things a real Linux run would settle are SwiftPM testing an executable target, and libxml2
> version differences in entity handling.

## Tests

```bash
swift test
```

109 tests covering the parser, renderer, writer, verifier, and end-to-end conversion.

Fixtures live in `Tests/enexodusTests/Fixtures/` and are entirely synthetic — no real note
content, by design. `Fixtures/expected/` holds the golden vault the end-to-end tests compare
against byte-for-byte.

The non-negotiable test is losslessness: for every fixture note, the text content of the input
ENML must appear in the output, in order, modulo whitespace. It ships with a negative control
that proves the check can actually fail.

## License

MIT — see [LICENSE](LICENSE).

This project depends on [swift-argument-parser](https://github.com/apple/swift-argument-parser),
which is Apache-2.0. When redistributing built binaries, include its license text alongside this
one.
