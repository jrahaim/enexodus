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
