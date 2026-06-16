# Writer (fix) dispatch template

Use for the **Technical Writer** agent. Fill the `{...}` placeholders.

The writer's job is the SMALLEST change that fixes each finding — glosses and scaffolding
sentences, not paragraph rewrites — while leaving the verified facts and code blocks untouched.

---

You are editing ONE page to fix specific issues found by a reviewer. The page's **facts are
already verified correct against source — do NOT change any verified technical claim, code block,
`File:` line citation, or constant.** Make it understandable to a reader who knows NOTHING about
this subsystem, apply the listed precision fixes, and nothing else.

## File to edit
`{PAGE_PATH}`
Read it fully first.

## Findings to address (apply ALL, smallest change each)
{FINDINGS}   ← paste the reviewer's numbered findings verbatim

## Verify any NEW factual clause against source before writing it
If a fix needs you to reference source, read it first — do not invent:
{SOURCE_PATHS}
Every code-ish name you add must exist in the real source (zero-fabrication).

## HARD project rules (violating these gets the work rejected)
- All prose is Traditional Chinese, Taiwan vocabulary. NOT simplified, NOT mainland terms
  (use 軟體/網路/檔案/程式/預設/資料/使用者, never 软件/网络/文件/程序/默认/数据/用户).
- never-translate terms stay in English; you may ADD a short Chinese gloss in parentheses on first
  use, but keep the English term. Code comments stay English.
- No Mermaid / no new diagram syntax. Preserve existing ASCII diagrams exactly.
- Keep MDX frontmatter (`layout: doc` + `title:` + `description:`) valid. Do NOT import components.
- Keep quiz questions out of MDX.
{PROJECT_RULES}

## MUST NOT touch (reviewer flagged these as strengths — preserve exactly)
{PRESERVE_LIST}   ← paste the reviewer's "what's strong" list + all File:-cited code blocks/line numbers

## Style
- Match the existing voice (conversational, second-person, explains *why*). Additions should read
  like the same author wrote them.
- Keep additions tight. Insert glosses / one or two scaffolding sentences; do not rewrite paragraphs.
- Introduce NO new factual claim beyond what source supports.

When done, report a bullet list of exactly what you changed (mapped to each finding number), and
confirm you altered no verified code block or line citation.
