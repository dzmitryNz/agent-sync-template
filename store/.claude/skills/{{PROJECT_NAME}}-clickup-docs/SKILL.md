---
name: {{PROJECT_NAME}}-clickup-docs
description: "House style for writing or editing {{PROJECT_NAME}} documentation pages in ClickUp (Documentation space, workspace {{CLICKUP_WORKSPACE_ID}}, doc {{CLICKUP_DOC_ID}}). Use whenever creating or updating a ClickUp doc page for {{PROJECT_NAME}} — product docs, how-it-works pages, simplified/manager-facing explainers, PRDs. Covers: plain English B1 language requirement, no audience-labeling banners, no self-justifying commentary, worked-number examples over vague descriptions, an anti-slop checklist against generic AI-writing tells (buzzwords, em dashes, inline-header bullet lists, fake confidence, filler conclusions), and the update_document_page replace-mode data-loss trap. Trigger terms: ClickUp doc, ClickUp documentation, How it works page, update_document_page, worked examples, simplified doc for manager, AI slop, generic AI doc."
---

# {{PROJECT_NAME}} ClickUp documentation style

Rules learned the hard way while writing "How it works" pages in ClickUp (workspace `{{CLICKUP_WORKSPACE_ID}}`, doc `{{CLICKUP_DOC_ID}}`). Apply these to any {{PROJECT_NAME}} ClickUp doc page.

## Language

- **All ClickUp doc content is English, plain, B1 level** — short sentences, common words, no idioms, no jargon left unexplained. This holds even when the chat with the user is in {{USER_LANGUAGE}} — the doc itself is always English B1.
- Repo markdown docs (`docs/*.md`) can stay in whatever language the repo already uses; this rule is specifically for ClickUp pages.

## Tone

- **Never label a page's audience** ("for managers", "for a non-technical reader", "simplified version for X"). State the content; let the reader decide it's simple. A banner announcing "this is the easy version" reads as condescending. If you need to link between a detailed page and a worked-examples page, describe what's on the other page ("full technical version" / "worked examples"), not who it's for.
- **No self-justifying asides.** Don't write "checked on prod", "verified in the code", "I confirmed this" inside the document — a doc is assumed to state the truth, not prove it isn't made up. Do the fact-checking (read the code, query the DB) before writing, silently. Only mention how something was verified if the user explicitly asks for that detail.
- **No moralizing parentheticals.** Don't append "(specially chosen so that X doesn't happen)" or similar justification-for-a-child asides after a number or rule. State the fact (`−5`) and stop. If the *why* is genuinely load-bearing for understanding, put it in one short clause, not a parenthetical lecture.
- Write for an adult colleague, not a student — assume the reader can infer implications from a clean fact.

## Prefer worked numeric examples over descriptions

When a rule has thresholds or bands (discount steps, timing windows, cooldowns), don't describe them in prose ("within the acceptable window"). Instead:
- Pick one concrete anchor (e.g. an order total of 100).
- Table every band with its exact range, in both directions if the rule is two-sided.
- Follow with a bullet list of concrete inputs mapped to outcomes ("order 120 → 10% off → 108"), including boundary cases and the "beyond the last band" case explicitly, even if it pays the same as the last band — that's exactly the case readers get confused about.
- Source the actual numbers from the code/DB (e.g. the `pricing_rules` default row) rather than inventing plausible-looking ones — but keep the sourcing note out of the reader-facing prose (see Tone above); a short dated footnote line at the bottom of the page is fine for that.

## Anti-slop checklist (why manager complaints keep happening)

Manager feedback on generated docs ("this reads like AI wrote it") maps to specific,
checkable patterns — not a vague vibe. Adapted from the `antislop-copywriting` rules in
[miqdadbadjuber/anti-slop](https://github.com/miqdadbadjuber/anti-slop). Run this before
publishing any ClickUp doc page:

- [ ] **No inline-header bullet lists** — `- **Performance:** load times improved` style
  lists. This is the single most common AI tell in generated docs. Write a plain
  paragraph, or a real table with columns, instead of a bolded-label bullet list.
- [ ] **No buzzwords** — unlock, elevate, empower, seamless, robust, cutting-edge,
  game-changer, next-level, journey, landscape. Replace with the concrete mechanism
  ("cuts the time to X" not "elevates your workflow").
- [ ] **No signposting** — "Let's dive in", "Here's what you need to know", "In this doc
  we'll explore". Start with the fact itself.
- [ ] **No generic filler conclusion** — "this opens up new possibilities", "a big step
  forward", "the future looks bright". End on the last concrete fact, or cut the closing
  paragraph entirely.
- [ ] **No fabricated specifics** — invented numbers, example names, or "typically"/"in
  most cases" claims not sourced from code or DB. Every number in the doc must trace to
  something you actually checked (see worked-numeric-examples rule above).
- [ ] **No em dashes** — replace with period, comma, or colon depending on the relationship.
- [ ] **No forced rule-of-three or "not just X, it's Y"** parallelism. State the one point
  that matters.
- [ ] **Minimal boldface, no emoji headings** — bold only genuinely key terms, not every
  noun phrase; no decorative emoji in section headers.
- [ ] **Read it aloud once before publishing.** If it sounds like a template filled in
  rather than someone describing a system they understand, rewrite the paragraph.

This checklist is about surface tells, not the content rules above (language, tone,
worked examples) — run both. A doc can fail the anti-slop checklist while still being
factually correct and B1-plain, and that's exactly the kind of doc that gets the "AI
slop" complaint.

## `update_document_page` replace-mode trap

`content_edit_mode: "replace"` (the default) **overwrites the entire page**, not just the part you're thinking about. There is no targeted string-replace mode for existing content — only `append`, `prepend`, or whole-page `replace`.

Before any `replace` edit to an existing page:
1. Call `get_document_pages` first and capture the full current content.
2. Build your edit as the full new body (old content with your change applied), never a short snippet.
3. Never call `replace` with only the lines you intended to change — that silently deletes everything else, and there's no undo prompt.
4. After publishing, re-fetch the page and sanity-check length/structure before moving on, especially after several edits in a row on the same page.

If you only need to add a line at the very top or bottom, use `content_edit_mode: "prepend"` / `"append"` instead of `replace` — those merge server-side and don't require re-sending the whole body.
