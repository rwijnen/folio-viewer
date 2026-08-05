# Third-party notices

Folio ships one piece of third-party code. Everything else in this repository is
original work under the [MIT licence](LICENSE).

## mermaid

- **File:** `Resources/Web/mermaid.min.js` (copied into `Folio.app/Contents/Resources/`)
- **Version:** 11.16.1
- **Source:** <https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js>
- **Project:** <https://github.com/mermaid-js/mermaid>
- **Licence:** MIT
- **SHA-256:** `18327bef70d96fb505fe7287d9f6a7362ebf07ff6576ddfaffb1a06f3e1a2954`

The full licence text, together with the notices for mermaid's own dependencies
(d3, dompurify, khroma, and others), is preserved in the banner comments inside the
minified file itself.

It is **vendored deliberately** rather than fetched at build or run time, so that
diagrams render with no network access at all and a build is reproducible offline.
`Resources/Web/mermaid-PROVENANCE.txt` records the same details next to the file, and
`.gitattributes` marks it as vendored so it does not skew GitHub's language statistics.

To update it, download the same URL at a newer version, replace both the file and the
recorded checksum, and re-run the test suite — `swift test` covers the page assembly
that loads it.
