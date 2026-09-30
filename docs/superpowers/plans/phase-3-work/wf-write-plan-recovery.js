export const meta = {
  name: 'phase3-write-plan-tasks-recovery',
  description: 'Recover rate-limited groups: write+review+revise Tasks 1-5 and 11; review+revise the existing drafts of Tasks 6-10',
  phases: [
    { title: 'Write', detail: 'seven writer groups draft full TDD tasks against the contract' },
    { title: 'Review', detail: 'codebase-fit and silent-failure reviewers per group' },
    { title: 'Revise', detail: 'writer applies verified findings' },
  ],
}

const ROOT = 'D:\\PROJECTS\\medical_inventory'
const SP = ROOT + '\\docs\\superpowers\\plans\\phase-3-work'
const CONTRACT = SP + '\\contract.md'
const SCOPES = SP + '\\scopes.md'
const FACTS = SP + '\\facts'
const PARTS = SP + '\\plan-parts'
const SPEC = ROOT + '\\docs\\superpowers\\specs\\2026-09-27-medical-inventory-design.md'
const DRAFT = ROOT + '\\docs\\superpowers\\plans\\2026-09-27-phase-3-ordering-fefo.md'
const P2 = ROOT + '\\docs\\superpowers\\plans\\2026-09-27-phase-2-catalog-warehouse.md'
const RESUME = ROOT + '\\docs\\RESUME.md'

const COMMON = `
You are writing PART of an implementation plan (a markdown document). You are NOT implementing the feature.
HARD RULE: do not create, modify or delete anything under ${ROOT} except your one output file under ${PARTS}. Everything else is read-only (reading files and running read-only commands such as \`npx prisma --version\`, \`npx prisma migrate diff --help\`, \`git show\`, \`ls\` is fine). Your ONLY write is your output file under ${PARTS}.

Read first, fully:
- The CONTRACT: ${CONTRACT} — binding. Decisions D1-D20, schema, error codes, file paths, signatures, test helpers, Dart APIs. Do not invent cross-task names; if something is missing, choose the most natural name, use it consistently, and list it under "Open questions".
- The SCOPE file: ${SCOPES} — your group's section lists every REQUIRED test case and file for your tasks.
- Fact sheets in ${FACTS}: backend-data.md, backend-http-tests.md, api-client.md, uikit-admin.md, client-app.md (read the ones relevant to your tasks; they describe the as-built code exactly, including gotchas).
- Critic findings on the old draft in ${FACTS}\\critique-*.json (the contract already resolves them; read them so your tests pin the failure modes they describe).
- The spec: ${SPEC} (sections 5, 7.1, 7.3, 7.4, 7.7, 7.9, 10, 11, 12 as relevant).
- The draft plan being replaced: ${DRAFT} — reuse its voice (short, pointed "why" commentary) but NOT its defects (its Tasks 1-2 are superseded by the contract).
- Style reference for a finished task: ${P2}, Task 7 "Warehouse batches" (search for "## Task 7:"), and ${RESUME} for as-built deviations (Vitest not jest, vi.fn(), explicit rootDir, Prisma 7 config, Riverpod 3 without StateProvider, committed l10n files).
- The real source files you will modify or build on: open them and copy exact text for every "replace this" snippet.

Plan-writing rules (superpowers:writing-plans — mandatory):
- Each task: "## Task N: <Title>", then "**Files:**" (Create / Modify / Test, exact repo-relative paths), then "**Interfaces:**" with "- Consumes:" and "- Produces:" listing exact signatures, then steps "- [ ] **Step k: <action>**".
- TDD order: write the failing test (COMPLETE code) -> run it (exact command, e.g. \`cd backend && npm run test:e2e -- test/e2e/cart.e2e-spec.ts\`, \`cd backend && npm test -- test/unit/x.spec.ts\`, \`cd packages/api_client && dart test test/x_test.dart\`, \`cd client && flutter test test/x_test.dart\`) and state the expected failure -> implement (COMPLETE code) -> run (expected PASS) -> \`cd backend && npm run typecheck\` or \`flutter analyze\` + \`dart run ui_kit:check_colors lib\` -> commit (\`git add <exact paths>\` + \`git commit -m "<conventional message>"\`).
- NO placeholders: no "TBD", "similar to Task N", "add validation", "handle edge cases", "write tests for the above", "...rest unchanged" inside code you are asking someone to type. Every code step shows complete code. For a modification to an existing file, show the exact current snippet (copied from the real file) and its exact replacement, or show the whole new file.
- Comment density and idiom match the surrounding code: explanatory comments say WHY (the failure they prevent), as in backend/src/warehouse/batches.service.ts.
- Tests must be able to fail for the right reason. Where a test guards a concurrency or boundary claim, add a step that proves it can fail (what to temporarily remove, what failure to expect, then restore).
- Every helper you use must come from the contract (section 4) or be defined in your task with full code.
- Keep backend money as Prisma.Decimal and Dart money as String. Never Arabic literals in Flutter widgets (use l10n; tests may use Arabic literals). No colour literals outside palette.dart. EdgeInsetsDirectional only.
- At the end of your file add "### Open questions (for the plan author)" listing every assumption the contract did not settle (or "None").
Return value: a short summary (at most 15 lines): tasks written, output path, line count, open questions.`

const GROUPS = [
  { key: 'A-data-fefo', tasks: '1, 2, 3', out: PARTS + '\\A-tasks-01-03.md' },
  { key: 'B-cart-place', tasks: '4, 5', out: PARTS + '\\B-tasks-04-05.md' },
  { key: 'C-confirm-deliver-cancel', tasks: '6, 7, 8', out: PARTS + '\\C-tasks-06-08.md' },
  { key: 'D-availability-hotdeals', tasks: '9, 10', out: PARTS + '\\D-tasks-09-10.md' },
  { key: 'E-api-client', tasks: '11', out: PARTS + '\\E-task-11.md' },
  { key: 'F-uikit-client', tasks: '12, 13, 14, 15', out: PARTS + '\\F-tasks-12-15.md' },
  { key: 'G-admin', tasks: '16, 17', out: PARTS + '\\G-tasks-16-17.md' },
]

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          location: { type: 'string' },
          problem: { type: 'string' },
          evidence: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['severity', 'location', 'problem', 'evidence', 'fix'],
      },
    },
  },
  required: ['findings'],
}

const REVIEW_COMMON = (g) => `
You are an adversarial reviewer of one part of an implementation plan. The part covers Tasks ${g.tasks} and is at ${g.out}.
Binding references: the CONTRACT ${CONTRACT}; the SCOPE file ${SCOPES} (section "Group ${g.key}" lists every required case); fact sheets in ${FACTS}; spec ${SPEC}; the real code under ${ROOT} (read-only — do not modify anything; do not write files).
The executor will follow this part literally with zero extra context. Report ONLY verified defects: open the real files, check the contract, reason through the code. Each finding needs concrete evidence (quote the plan text and the real code/contract/spec line that contradicts it) and a concrete fix (replacement text/code). Drop anything you cannot substantiate. Do not report style nits. If the part is missing entirely or is empty, report that as critical. Report any required scope case that is missing or only superficially tested.`

const LENSES = [
  {
    key: 'fit',
    prompt: `LENS: CODEBASE FIT AND EXECUTABILITY. Would every step work if typed literally? Check: every import path and exported name exists (or is created earlier in the plan/contract); Prisma 7 API and raw-SQL syntax (quoted camelCase columns, table names from @@map, ::text[] / ::date casts, count(*)::int, enum ::text casts, gen_random_uuid() + updatedAt in raw inserts, $queryRaw vs $executeRaw return types, P2010 wrapping of raw errors); NestJS decorators, DTO validation (class-validator + @Type for nested/query numbers; forbidNonWhitelisted), module registration; Vitest APIs (vi not jest; vi.useFakeTimers({ toFake: ['Date'] })); supertest usage; Dart/Flutter APIs (Riverpod 3 without StateProvider, go_router 17, FakeApiBackend handler signature, l10n generation, check_colors); that every "old snippet" to replace matches the real file EXACTLY; that commands and file names match the harness (e2e files *.e2e-spec.ts in test/e2e, integration *.spec.ts in test/integration); that each failing-test step would fail for the stated reason; that types line up across tasks and with the contract; no placeholders.`,
  },
  {
    key: 'behaviour',
    prompt: `LENS: BEHAVIOUR AND SILENT FAILURE. Does the code do what the spec and contract decisions D1-D20 require, and would the tests catch it if it did not? Hunt for: wrong movement sign/reason/owner; stock moved outside AllocationService; missing or wrong lock order (order row -> batches); settings read inside a transaction; business-date vs UTC mistakes; money via floats or wrong rounding; totals not recomputed from lines; disposition/status/timestamp combinations that violate the CHECKs; tests that pass vacuously (allSettled swallowing errors, assertions only on upper bounds, concurrency tests that are not actually concurrent, fixtures that bypass the code under test, counts that include rows from other tests); required scope cases missing; for Flutter: requirement 18 (+ has no text), RTL (EdgeInsetsDirectional, no reverse: on the PageView), Arabic literals in widgets, colour literals, stale per-user state after logout, legacy tests broken by new home-screen requests, timers not cancelled, Riverpod auto-retry making call counts flaky.`,
  },
]

const REVISE = (g, findings) => `
${COMMON}

You are responsible for the plan part for Tasks ${g.tasks} at ${g.out} (scope: section "Group ${g.key}" of ${SCOPES}). Two adversarial reviewers checked it. Their findings are below as JSON.
For EACH finding: verify it yourself against the real code/contract/spec. If valid, fix the part file in place (Edit/Write on ${g.out} only). If invalid, do not change the file for it and record why.
Also re-check your scope section once more and add anything still missing.

Findings:
${JSON.stringify(findings, null, 2)}

Return: a short report — for each finding "applied" or "rejected: <reason>" (one line each), then the updated "Open questions" list.`

const WRITE = new Set(args.write)
const REVIEW_ONLY = new Set(args.reviewOnly)
const SELECTED = GROUPS.filter((g) => WRITE.has(g.key) || REVIEW_ONLY.has(g.key))
log(`writing: ${[...WRITE].join(', ')}; reviewing existing drafts: ${[...REVIEW_ONLY].join(', ')}`)

phase('Write')
const results = await pipeline(
  SELECTED,
  (g) => REVIEW_ONLY.has(g.key)
    ? Promise.resolve({ g, summary: 'existing draft (written in the first run; its review was lost to a rate limit)' })
    : agent(
        `${COMMON}\n\nYOUR TASKS: ${g.tasks}. Your scope is section "Group ${g.key}" of ${SCOPES}. Output file: ${g.out}`,
        { label: 'write:' + g.key, phase: 'Write' },
      ).then((summary) => ({ g, summary })),
  (w) => parallel(LENSES.map((l) => () =>
    agent(`${REVIEW_COMMON(w.g)}\n\n${l.prompt}`, { label: `review:${w.g.key}:${l.key}`, phase: 'Review', schema: FINDINGS })
      .then((r) => ({ lens: l.key, findings: r ? r.findings : [] }))
  )).then((reviews) => ({ ...w, reviews: reviews.filter(Boolean) })),
  (r) => {
    const all = r.reviews.flatMap((x) => x.findings.map((f) => ({ lens: x.lens, ...f })))
    log(`${r.g.key}: ${all.length} findings (${all.filter((f) => f.severity === 'critical' || f.severity === 'high').length} critical/high)`)
    return agent(REVISE(r.g, all), { label: 'revise:' + r.g.key, phase: 'Revise' })
      .then((report) => ({ key: r.g.key, out: r.g.out, writeSummary: r.summary, findingCount: all.length, findings: all, reviseReport: report }))
  },
)
return results.filter(Boolean)
