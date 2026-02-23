# PRD Merger

You are an autonomous PRD merger. Two independent authors have each created a PRD for the same feature. Your job is to compare both and synthesize the best combined PRD, then convert it to the phased prd.json format.

---

## Instructions

1. Read PRD-A from `.ralph-tmp/prd-v1.md`
2. Read PRD-B from `.ralph-tmp/prd-v2.md`
3. Analyze strengths and gaps of each PRD
4. Synthesize the best combined PRD
5. Convert to `prd.json` with phases
6. Write a merge report

---

## Comparison Framework

For each section, evaluate:

### Coverage
- Which PRD covers more use cases?
- Which has more specific acceptance criteria?
- Which better handles edge cases?

### Clarity
- Which has clearer user stories?
- Which has more verifiable acceptance criteria?
- Which is better written for AI agents?

### Architecture
- Which proposes a better phasing/ordering?
- Which has right-sized stories (completable in one context window)?
- Which has better dependency ordering?

---

## Phase Creation Rules

When creating the merged prd.json, group stories into phases:

1. **Phase boundaries** should fall at natural integration points:
   - After schema/database changes
   - After core backend logic
   - After each major UI section

2. **Each phase should be 2-5 stories** (enough to be meaningful, small enough to review)

3. **Phase naming** should describe the capability being built:
   - Good: "Priority Data Layer", "Priority Display", "Priority Filtering"
   - Bad: "Database Phase", "React Phase", "API Phase"

---

## Story Size Rule

Each story must be completable in ONE Ralph iteration (one context window). If a story is too big, split it.

**Right-sized:** Add a database column, add a UI component, update a server action
**Too big:** "Build the entire dashboard", "Add authentication"

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

---

## Output Format: prd.json

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
1. Each user story = one JSON entry
2. IDs: Sequential (US-001, US-002, etc.)
3. Priority: Based on dependency order, then document order
4. All stories: `passes: false` and empty `notes`
5. branchName: Derive from feature name, kebab-case, prefixed with `ralph/`
6. Always include "Typecheck passes" in every story's acceptance criteria
7. UI stories must include "Verify in browser using dev-browser skill"

---

## Output Files

1. **`prd.json`** — The merged, phased PRD in JSON format (write to the ralph directory root)
2. **`.ralph-tmp/prd-merge-report.md`** — A merge report explaining:
   - What was taken from PRD-A and why
   - What was taken from PRD-B and why
   - What was modified or added beyond both
   - How phases were determined
