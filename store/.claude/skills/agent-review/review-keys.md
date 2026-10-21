# Review finding keys

Every finding in `[REVIEW RESULT]` starts with `[<category>/<key>]`. By the key
`/pr-review-retro` (`mine_review_results.py`) groups repeats across PRs — a key invented
anew for the same mistake hides the repeat.

Rules:
- Look for a fitting key here first. A new one only if none describes the mistake;
  then add a line to this file in the same review.
- A key is kebab-case, about the **type of mistake**, not the place: `check-then-write`,
  not `order-status-field`.
- The category is one of five: `correctness`, `simplification`, `efficiency`,
  `security`, `style`. No other categories: `docs/`, `tests/`, `pr/` split one mistake
  into many groups. Use the canonical key, not a synonym:
  PR body (`pr-body-mismatch`, `pr-body-claim`, `body-mismatch`) → `style/pr-body-inaccurate`;
  stale comment or doc next to the change → `style/stale-comment`;
  missing test (`coverage-gap`, `missing-case`) → `correctness/test-gap`;
  `mirror-implementation` → `correctness/test-mirrors-impl`.
  `mine_review_results.py` maps these synonyms too, but only the known ones.
- If nothing fits and the finding is one-off — `<category>/other`.

## correctness

- `null-guard` — dereferencing something that may be null/undefined.
- `missing-field-default` — optional API field absent; a default (0/false/[]) opens a path that would be blocked if the field were present.
- `check-then-write` — the check and the write are separate queries, state changes between them.
- `async-ordering` — synchronous accounting/side effect sits behind an `await` or before success is confirmed; stale response without a guard. (Two DB writes with a check between them are `check-then-write`.)
- `silent-failure-swallowed` — an error or partial failure is swallowed: catch without log/throw, allSettled result discarded.
- `error-lacks-context` — a thrown error/log names a count or a generic failure but not the item that failed (missing key, id), so the operator must reproduce it to find out.
- `nullable-sql-filter` — `!= X` / `= X` on a nullable column silently drops NULL.
- `float-money-rounding` — money in float without rounding to the cent, comparisons and caps drift.
- `accepted-field-ignored` — a request field passes the schema and the endpoint answers 2xx, but the value is never applied (not priced, not stored, not paid): the user believes it took effect.
- `committed-artifact` — something extraneous got into the commit: a node_modules symlink, test-run logs.
- `migration-assumes-state` — a migration relies on an id/constraint/existence without checking, destructive without a guard.
- `migration-not-idempotent` — a migration is not safe to run twice. Idempotency is required and must be checked: a rerun on a database that already has the change must be a no-op (guard existing columns, indexes, and rows; do not drop or rewrite without a current-state check).
- `outbound-no-timeout` — fetch/axios/HTTP client without timeout or AbortSignal.
- `sibling-branch-missed` — fix in one branch/copy, the adjacent one with the same pattern left.
- `test-mirrors-impl` — the test checks SQL substrings/a mock chain instead of behavior.
- `test-gap` — changed behavior or a branch is not covered by a test.
- `zero-sentinel` — stores/returns 0 where NULL means "unknown", and 0 overrides the fallback in COALESCE.
- `test-silent-skip` — a test exits via `return`/warn when a precondition (table, env) is missing and counts as green; never executes in CI.
- `test-state-leak` — a test replaces shared state (config property, global) and restores it only on the happy path, after an `await`; a failure leaks the value into later tests.
- `scope-cut` — scope cut relative to Task.
- `access-rule-drift` — a migration/backfill derives grants with a rule that differs from the check it replaces (SQL `LIKE 'ns.%'` vs a client check over a fixed key list): access silently widens or narrows when data changes.
- `resource-leak` — object URLs, timers, subscriptions, connections are not released.
- `wrong-aggregation-weight` — an average/share is rolled up across periods with the weight of the wrong population (fired instead of resolved, etc.), the total is skewed.
- `client-server-limit-mismatch` — a limit/cap exists on the backend but not on the frontend (or vice versa): the user gets a 400 instead of an inline hint.
- `input-validation-gap` — input passes the schema but is invalid semantically (a nonexistent date, etc.) and causes a 500 instead of a 400.
- `sql-alias-not-joined` — an expression in WHERE/ORDER BY/SELECT references an alias that a conditional JOIN does not add for some inputs: `Unknown column` → 500.
- `write-to-unread-store` — data is written to a table or collection the runtime does not read (a legacy copy): the feature silently does not work.
- `closed-enum-response-schema` — the response schema has a closed union of literals for a value coming from a adjacent service: a new upstream value breaks fast-json-stringify serialization → 500 for the whole response.
- `amount-components-mismatch` — the total and its components are written inconsistently (total omits a retained part, remainder left on a full reversal).
- `upstream-contract-mismatch` — a call to a adjacent service diverges from its real contract (HTTP method/route, where auth/secret lives, response nesting), while the test mocks the shape the implementation expects.
- `schema-default-injected` — a `default` in the request schema (including one inherited via `Type.Partial`) is filled in by Ajv into a missing field: PATCH/guard see a "sent" value the client never sent.
- `non-idempotent-event-apply` — a delta (counter ±1, list push) is applied both by the local action and by the server's echo event for the same id, or by a repeated event: the state drifts twice.
- `text-match-false-positive` — a guard/hook matches a command by regex over text: fires on a mention in quotes/a commit message/a heredoc, while an equivalent form (options, `cd`, relative `-C`) slips past.
- `non-atomic-multi-write` — several dependent writes (row + flag, etc.) without a transaction or compensation: a failure in the middle leaves half the state and a retry duplicates the first write.
- `presence-stale-target` — recipients are picked by a stored online flag/socket id that one tab's disconnect clears while another tab of the same user stays connected: the live user gets nothing.
- `stale-unsaved-after-unmount` — FormSection / unsaved-changes store keeps `isUnsaved: true` after the form unmounts (tab switch, conditional render); close-confirm fires when nothing is in edit mode.
- `null-overwrite-existing` — an upsert assigns the fresh value directly, so an empty or failed parse overwrites a stored non-null value (or a placeholder overwrites a real type).
- `expected-miss-counted-as-failure` — a normal "not found" (404) is counted as a failure by a breaker/backoff and shuts a source down for the run.
- `transient-cached-as-permanent` — a skip/backoff cache meant for permanent errors (404) also stores transient ones (5xx, 429, gateway errors), so a short outage parks every target for the whole TTL.
- `timestamp-not-bumped` — a "retry/refresh after N days" rule keys on `updatedAt`, but the save skips the UPDATE when values are unchanged (TypeORM), so the row is re-selected forever.
- `probe-narrower-than-use` — a readiness/feature probe checks less than the code path then needs (one table of five, no grant check) and caches success: a partial setup passes the probe, then every real call fails with no fallback.
- `clear-replaced-by-live-guard` — a one-shot clear of stored state (null a column, delete a row) is replaced by a live condition in the read (`NOT EXISTS <flag>`): when the condition ends, the old state is read again, while the clear would have kept it gone.
- `row-state-index-keyed` — per-row UI state (open modal/popover, draft text) lives in a cell of a table without `rowKey`; a live list shift re-targets the open UI to a different row, or recycles and drops it.
- `cache-bypassed-by-local-state` — a cache with TTL/invalidation is added, but the consumer keeps its own copy (component state, module var) for longer and never re-reads the cache, so the invalidation has no visible effect.
- `target-set-too-broad` — a destructive or side-effect action (close, delete, notify) selects its targets by a condition wider than the intent ("anyone not accepted" instead of "the one who cancelled"), so it hits rows the task never meant.
- `guard-wider-than-case` — a fix adds a skip or ignore guard for one kind of input but keys it on a wider condition that also matches another kind, so valid updates of the second kind are dropped.
- `duplicate-spoken-name` — a user-facing list (spoken/printed) is built per item without dedupe, so one name repeats ("PM, PM").
- `ambiguous-write-outcome` — a non-idempotent write whose request was sent but whose answer was lost (timeout, body read error, unparseable 2xx) is reported as "unreachable"/"not saved"; the caller (often an LLM agent) retries and the write lands twice.
- `state-transition-side-effects` — a close/remove/release/reassign (or a no-op write) leaves a related row, event, counter or flag out of sync: reopened, orphaned, event skipped, never re-placed.
- `selection-predicate-mismatch` — a read query/filter picks rows by a condition wider or narrower than the intended entity: not scoped to bot/owner/segment, arbitrary `.first()` of a 1:N join, NULL read as a value, LIMIT hides rows. Destructive cases are `target-set-too-broad`.
- `ui-action-state-gap` — a control's enabled/loading/feedback state does not match the real action: no await or toast, the loading key differs from the sent key, a loader stuck after a failed load, a no-op save enabled.
- `stale-sibling-field` — a source value changes, but a field, draft or flag derived from it is not cleared or bumped (a derived distance stays after its source row is removed).
- `failure-blast-radius` — failure of an optional/enrichment step inside a shared try (or one bad item) fails the whole request, fan-out or startup.
- `test-env-diverges-from-prod` — test setup hand-copies or patches prod config/schema, so green does not prove prod behavior.
- `deploy-order-coupling` — the change reads something another PR/service ships (column, endpoint) and breaks if deployed first; or Deploy actions do not say so.
- `payload-type-assumed` — a parser/regex/lookup assumes the JSON type of a stored value (number) while a real writer stores another (string): the feature silently does nothing on real data, and tests with typed fixtures stay green.
- `collation-key-mismatch` — SQL groups/joins by a text key under a `_ci`/`_ai` column collation, while the returned key or the JS twin of the rule compares bytes: one SQL group carries several key strings, or SQL and JS group differently.
- `subquery-scope-mismatch` — a correlated EXISTS / "has a partner" check ignores the outer query's filters (date window, status, scope), so a row passes the 2+ rule while its partner is not in the result.

## security

- `leak-internal-errors` — raw text of upstream errors or internal enums goes to the client.
- `authz-missing` — no permission check on the action/data.
- `wrong-timestamp-semantics` — a rule keys on a timestamp column that does not mean what the rule needs (`created_at` of an upserted row that is re-activated, not re-created): the window is measured from the first event, not the latest one.

## efficiency

- `unbounded-query` — no LIMIT/ORDER BY/cap on the number of chunks or log size.
- `duplicate-query` — the same table is read twice where one query suffices.
- `serial-timeouts-in-loop` — outbound calls with a per-call timeout run one by one inside a scheduled tick; a hanging upstream stalls the tick for N x timeout.
- `migration-online-ddl` — `ADD KEY`/`ADD COLUMN` without explicit `ALGORITHM=INPLACE, LOCK=NONE` / `ALGORITHM=INSTANT`: MySQL may silently fall back to COPY and block writes on a hot table.

## simplification

- `duplicated-logic` — the same block in several places, begs for a helper.
- `dead-code` — after the change a method/branch is no longer called from src (only mocks in tests remain).

## style

- `schema-optional-mismatch` — `Type.Optional` in the schema diverges from the type/runtime.
- `stale-comment` — a comment/doc next to the change no longer matches the code.
- `pr-template` — the PR body is not per template, `docs/qa-checklist.md` was touched.
- `pr-body-inaccurate` — the PR body or a QA step describes behavior the code does not have (or no longer has).
- `doc-stale-claim` — a domain note/doc states a rule that the code/migrations have already replaced (rule removed, flag turned off).
- `doc-condition-incomplete` — a domain note/doc describes a condition wider than the code: skipped branches/exceptions where the rule does not fire.
- `ui-layout-nit` — a CSS/layout change looks wrong: wraps, sticky border lost, column width changed without reason, inline style where the repo uses CSS.
- `repo-hygiene` — a repo rule or tool check is broken: missing session log, `git diff --check`, prettier, PR not draft, version-bump collision.
- `ui-copy-misleading` — a UI label/aria reads differently from what the number from the API means (a statistic looks like a live value, a level like a flow).
