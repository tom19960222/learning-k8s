# Evidence Ledger Template

Use this as a temporary research dossier while building a source-first feature page. Keep the ledger in scratch notes or the task context unless the user asks to preserve it.

## Scope

- Project id:
- Source path:
- Source tag or commit:
- Topic:
- Target slug:
- Related spec/plan:
- Adjacent repos or docs checked:

## Source Evidence

| Claim | Source path:lines | Symbol or key | What the source proves | MDX section |
|---|---|---|---|---|
|  | `project/path/file.go:10-40` | `FunctionName` |  |  |

## Source Trace

1. Entry point:
2. Main call chain:
3. Kubernetes API interactions:
4. Runtime/network/storage side effects:
5. Status, metrics, or events:
6. Error/retry/feature-gate boundaries:
7. Tests that confirm behavior:

## Rejected Claims

| Claim | Why rejected | Search performed |
|---|---|---|
|  | No source evidence found | `rg -n "..." project/...` |

## MDX Checklist

- Frontmatter has `layout: doc`, `title:`, and useful `description:`.
- First section is `## 場景`.
- Page has one clear topic; broad side topics are linked or deferred.
- Every code block has a preceding explanation and a `File: ... (line N)` marker.
- No global component imports.
- No Mermaid.
- No GitHub blob URL as primary source.
- zh-TW wording uses Taiwan terms and preserves never-translate terms from `AGENTS.md`.
- Images, if any, are static PNG files under `next-site/public/diagrams/{project}/` and not placeholders.

## Integration Checklist

- `next-site/content/{project}/features/{slug}.mdx` exists.
- `next-site/lib/projects.ts` includes the slug in `features`.
- `featureGroups` places the slug in exactly one appropriate group.
- `learningPaths` are updated only if the page changes reading order.
- `next-site/content/{project}/feature-map.json` is updated if that project has one.
- `next-site/content/{project}/quiz.json` is updated only with source-backed questions.
- `make validate` passes before commit or completion claim.
