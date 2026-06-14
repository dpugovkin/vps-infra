# Diagrams

The `*.d2` files are the **source of truth** (text, diffable, brand-agnostic). The committed
`*.svg` files are the rendered output embedded in the docs.

| Source | Rendered | Used in |
|---|---|---|
| `architecture.d2` | `architecture.svg` | README, `learning-path.md`, Module 1 |
| `request-path.d2` | `request-path.svg` | Module 2 |
| `go-live.d2` | `go-live.svg` | Module 4 |

## Regenerate

No local tooling required — render via the hosted [Kroki](https://kroki.io) service:

```bash
for d in architecture request-path go-live; do
  curl -fsS -X POST https://kroki.io/d2/svg \
    -H "Content-Type: text/plain" \
    --data-binary @docs/diagrams/$d.d2 -o docs/diagrams/$d.svg
done
```

Or, with a local [`d2`](https://d2lang.com) binary:

```bash
d2 docs/diagrams/architecture.d2 docs/diagrams/architecture.svg
```

Edit the `.d2` source, re-render, and commit both files together.
