# Phase 3 plan — progress (inline session, 2026-09-29)

The user declined ultracode ("i cant afford ultracod"), so this is being done inline with no workflow.

## Done and VERIFIED by execution
Each part was run step by step in a scratch copy of `backend/` against the throwaway
databases `medinv_proto*`. Every "expected" count, failure message and proof step in
these parts was observed.
- `plan-parts/A-tasks-01-03.md` — Tasks 1-3. Totals after Task 3: 90 unit, 262 e2e.
- `plan-parts/B-tasks-04-05.md` — Tasks 4-5. Totals after Task 5: 184 unit, 308 e2e.

## Contract corrections made while verifying
- Two CHECKs accepted NULL-producing rows: a cancelled order with a NULL
  disposition, and a half-set approval. They are fixed in `contract.md` §1 and in
  Task 1, and tested.

- `plan-parts/C-tasks-06-08.md`: executed and corrected. Task 6 now appends
  holdOrderRowLock, and its Step 13 expects [200, 500]. Totals after Task 8: 184 / 349.
- `plan-parts/D-tasks-09-10.md`: executed. The proof wording is now precise. Totals
  after Task 10: 184 / 377. The backend is complete.

- `plan-parts/E-task-11.md`: written and executed. api_client has 98 tests, and analyze is clean.

- `plan-parts/F-tasks-12-15.md`: written and executed. ui_kit has 37 tests. The client has 71 tests, run from the plan text itself on a fresh copy.

## Remaining
2. Review Part G (16-17) by executing it.
3. Assemble the plan, run a consistency pass, and replace the old draft plan.
4. Clean up: drop the `medinv_proto*` DBs and run `npx prisma generate` in `backend/`.
   The prototype's generate wrote Phase 3 models into the shared `node_modules`.
