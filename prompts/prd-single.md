# Single PRD Author

You are an autonomous PRD author. Your job is to create a single, phased Product Requirements Document for the feature described below and output it directly as `prd.json`.

**Consider both perspectives in one pass:**
- **Technical depth:** Schema, APIs, data flow, error handling, performance, edge cases, dependencies.
- **User experience:** Workflows, UI edge cases, accessibility, error messages, loading/empty states, common user journeys.

---

## Feature Description

{{FEATURE}}

---

## Instructions

1. Explore the codebase to understand the project structure, existing patterns, and relevant code.
2. Create a PRD that covers this feature with right-sized user stories (completable in one context window).
3. Group stories into phases at natural integration points (see Phase Creation Rules below).
4. Write the result **directly to `prd.json`** in the project root (the same directory as this prompt).

**Important:**
- Do NOT implement any code. Only create the PRD.
- Do NOT write intermediate markdown PRDs (no prd-v1.md or prd-v2.md). Output only `prd.json`.
- You may optionally write a short `.ralph-tmp/prd-single-notes.md` if helpful for your reasoning; the required deliverable is `prd.json`.

---

## Phase Creation Rules

When creating phases in prd.json:

1. **Phase boundaries** should fall at natural integration points:
   - After schema/database changes
   - After core backend logic
   - After each major UI section

2. **Each phase should be 2-5 stories** (enough to be meaningful, small enough to execute in sequence).

3. **Phase naming** should describe the capability being built:
   - Good: "Priority Data Layer", "Priority Display", "Priority Filtering"
   - Bad: "Database Phase", "React Phase", "API Phase"

---

## Story Size Rule

Each story must be completable in ONE Ralph iteration (one context window). If a story is too big, split it.

**Right-sized:** Add a database column, add a UI component, update a server action
**Too big:** "Build the entire dashboard", "Add authentication"

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

**Dependency ordering:** Order stories so earlier stories don't depend on later ones. Schema/database first, then server/backend logic, then UI components, then summary/dashboard views.

---

## Output Format: prd.json

Write **exactly** this structure to `prd.json` in the project root:

```json
{
  "project": "[Project Name]",
  "branchName": "ralph/[feature-name-kebab-case]",
  "description": "[Feature description]",
  "orchestration": {
    "currentPhaseIndex": 0,
    "status": "executing",
    "dualPrdComplete": true,
    "maxPlanRetries": 2
  },
  "phases": [
    {
      "id": "phase-1",
      "title": "[Phase Title]",
      "description": "[What this phase accomplishes]",
      "order": 1,
      "status": "pending",
      "reviewApproved": false,
      "reviewNotes": "",
      "planVersion": 0,
      "userStories": [
        {
          "id": "US-001",
          "title": "[Story title]",
          "description": "As a [user], I want [feature] so that [benefit]",
          "acceptanceCriteria": [
            "Criterion 1",
            "Criterion 2",
            "Typecheck passes"
          ],
          "priority": 1,
          "passes": false,
          "notes": ""
        }
      ]
    }
  ]
}
```

### Conversion Rules
1. Each user story = one JSON entry.
2. IDs: Sequential (US-001, US-002, etc.).
3. Priority: Based on dependency order, then document order.
4. All stories: `passes: false` and empty `notes`.
5. branchName: Derive from feature name, kebab-case, prefixed with `ralph/`.
6. Always include "Typecheck passes" in every story's acceptance criteria.
7. UI stories must include "Verify in browser using dev-browser skill".

### Acceptance criteria quality
- Criteria must be verifiable (e.g. "Add status column to tasks table with default 'pending'", not "Works correctly").
- Every story: "Typecheck passes".
- Stories with logic: "Tests pass" where applicable.
- UI stories: "Verify in browser using dev-browser skill".

---

## Output

1. **`prd.json`** — The phased PRD in JSON format, written to the project root (ralph directory).
2. Optionally **`.ralph-tmp/prd-single-notes.md`** — Short notes on phasing or tradeoffs, if helpful.
