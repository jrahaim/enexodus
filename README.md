# enexodus

Converts Evernote ENEX exports into a folder-per-notebook Markdown archive.

> **Status: Phase 1.** Built against the WP-1..WP-6 plan. The public-release polish
> (configurable layout, CI matrix, prebuilt binaries) is Phase 2 and deliberately not started.

## Usage

```bash
swift build -c release
.build/release/enexodus convert --input ~/EvernoteExport --output ~/Vault
.build/release/enexodus verify  --input ~/EvernoteExport --output ~/Vault
```

`--input` is a directory of `.enex` files, one per notebook. ENEX does not record the notebook
name, so the **filename is the notebook name**.

| Flag | Command | Meaning |
| --- | --- | --- |
| `--clean` | convert | Delete each target notebook directory before writing it |
| `--spacing tight\|faithful` | convert | Blank-line spacer policy (default `tight`) |
| `--quiet` | convert | Print only the summary |
| `--json` | verify | Emit the report as JSON |

`verify` exits non-zero on any mismatch.

## Output layout

```
<output>/
  <Notebook Name>/
    <Note Title>.md
    _attachments/
      <resource files>
```

Each note gets YAML frontmatter (`title`, `created`, `updated`, `tags`, `source-url` when
present, `notebook`, `enex-source`) followed by the rendered body.

## Design

**Evernote's `<div>` is a line, not a paragraph.** Evernote writes one `<div>` per visual line
and an explicit `<div><br/></div>` where the author wanted a blank one. Treating every div as a
paragraph double-spaces the whole archive and destroys the author's real structure, so
consecutive divs become consecutive lines and only spacer divs break a paragraph.

Related consequences of that model:

- Lines within a block are joined with a plain newline, which Obsidian renders as a line break.
  Strict CommonMark treats it as a soft break; the Phase 2 output-flavour toggle is where that
  becomes selectable.
- `<en-todo>` leading *any* block container becomes `- [ ]` / `- [x]`, not only inside `<li>`.
  `<div><en-todo/>text</div>` is the shape Evernote's own checklists use.
- A container whose text is entirely in a monospace font becomes a fenced code block, and
  consecutive such lines fuse into one fence. Older exports have no `--en-codeblock` marker —
  in one real 255-note export only 2 notes used it, versus 37 using monospace fonts.
- **Spacing (default `tight`).** Drops blank lines in notes that put one after *every* line — a typing
  habit rather than structure. Notes that use blank lines selectively are left untouched, and a
  run of two or more spacers always survives as one blank line. On a real 16-note notebook it
  changed 3 notes and left 13 alone. `--spacing faithful` reproduces every spacer instead.
- U+00A0 and friends are normalized to ordinary spaces. Evernote uses non-breaking space as its
  everyday word separator, which silently breaks Obsidian search and `grep`. Whitespace is
  outside the losslessness contract, so this is safe.

**Lossless over pretty.** ENML that does not map cleanly onto Markdown is emitted as sanitized
inline HTML rather than approximated or dropped. Every such block is preceded by
`<!-- enexodus:html-fallback reason="..." -->`, and an `<en-media>` whose hash matches no
resource leaves `<!-- enexodus:missing-resource ... -->` where it stood. Both markers are
counted by `verify`, so nothing is lost silently.

Sanitization removes `<script>`, `<iframe>`, `on*` handlers and `javascript:` URLs. It removes
nothing else — structure and text are kept intact.

**Deterministic.** Output depends only on the ENEX content and note order; there are no
run timestamps. Converting twice produces byte-identical files, so a re-run is an empty
`git diff`.

**Independent verification.** `verify` computes each count twice — once by re-parsing the ENEX,
once by reading only the files on disk — and compares. Neither number is derived from the other.

**Streaming.** Notes are parsed and written one at a time. Measured peak RSS is ~16 MB whether
the input is 72 MB, 290 MB, or 580 MB.

No network access at runtime; the Evernote DTD is never fetched. The only dependency is
`swift-argument-parser`.

## Requirements

macOS 14+ or Linux. Swift 6.0+.

## Tests

```bash
swift test
```

Fixtures live in `Tests/enexodusTests/Fixtures/` and are entirely synthetic — no real note
content. `Fixtures/expected/` holds the golden vault the end-to-end tests compare against
byte-for-byte.
