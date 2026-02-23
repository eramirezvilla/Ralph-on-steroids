---
name: dual-prd
description: "Generate a PRD using dual-author synthesis. Two perspectives (technical + UX) are independently created and merged into a superior combined PRD. Use when planning a feature with higher quality requirements. Triggers on: dual prd, create dual prd, two-author prd, synthesized prd."
user-invocable: true
---

# Dual-Author PRD Generator

Create a superior PRD by synthesizing two independent perspectives: one focused on technical depth, the other on user experience.

---

## The Job

1. Receive a feature description from the user
2. Ask 3-5 essential clarifying questions (with lettered options)
3. Create **two independent PRDs** with different lenses
4. Compare and merge into a single, superior PRD
5. Convert to phased `prd.json` format
6. Save the final PRD and merge report

**Important:** Do NOT start implementing. Just create the PRD.

---

## Step 1: Clarifying Questions

Ask only critical questions where the initial prompt is ambiguous. Focus on:

- **Problem/Goal:** What problem does this solve?
- **Core Functionality:** What are the key actions?
- **Scope/Boundaries:** What should it NOT do?
- **Success Criteria:** How do we know it's done?

### Format Questions Like This:

```
1. What is the primary goal of this feature?
   A. Improve user onboarding experience
   B. Increase user retention
   C. Reduce support burden
   D. Other: [please specify]

2. Who is the target user?
   A. New users only
   B. Existing users only
   C. All users
   D. Admin users only
```

This lets users respond with "1A, 2C, 3B" for quick iteration. Remember to indent the options.

---

## Step 2: Dual PRD Creation

After getting answers, create **two PRDs internally** using different lenses:

### PRD-A: Technical Depth Lens
Focus on: database schema design, API contracts, data flow, error handling, performance considerations, edge cases in backend logic. Think about what could go wrong technically and what the non-obvious dependencies are.

### PRD-B: User Experience Lens
Focus on: user workflows, UI edge cases, accessibility, error messages, loading states, empty states, progressive disclosure. Think about what the user actually needs and what the most common user journeys are.

Both PRDs should follow the same structure (see Step 3).

---

## Step 3: PRD Structure

Each PRD should have these sections:

### 1. Introduction/Overview
Brief description of the feature and the problem it solves.

### 2. Goals
Specific, measurable objectives (bullet list).

### 3. User Stories
Each story needs:
- **Title:** Short descriptive name
- **Description:** "As a [user], I want [feature] so that [benefit]"
- **Acceptance Criteria:** Verifiable checklist

Each story should be small enough to implement in one focused session.

**Format:**
```markdown
### US-001: [Title]
**Description:** As a [user], I want [feature] so that [benefit].

**Acceptance Criteria:**
- [ ] Specific verifiable criterion
- [ ] Another criterion
- [ ] Typecheck/lint passes
- [ ] **[UI stories only]** Verify in browser using dev-browser skill
```

### 4. Functional Requirements
Numbered, explicit requirements.

### 5. Non-Goals (Out of Scope)
What this feature will NOT include.

### 6. Design Considerations (Optional)
### 7. Technical Considerations (Optional)
### 8. Success Metrics
### 9. Open Questions

---

## Step 4: Merge

Compare the two PRDs and synthesize the best combined version:

### Comparison Criteria
- **Coverage:** Which covers more use cases and edge cases?
- **Clarity:** Which has more verifiable acceptance criteria?
- **Architecture:** Which has better story sizing and ordering?

### Merge Rules
- Take the best elements from each PRD
- If both have a story for the same thing, pick the one with better acceptance criteria
- If one PRD found an edge case the other missed, include it
- Group stories into **phases** (2-5 stories each, at natural integration boundaries)

---

## Step 5: Convert to prd.json

Save the merged result as `prd.json` with the phased format:

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
      "userStories": [...]
    }
  ]
}
```

### Phase Grouping
- Schema/database changes → Phase 1
- Backend logic/services → Phase 2
- UI components → Phase 3
- Dashboard/aggregation views → Phase 4
- Phase titles describe capabilities, not technologies

### Story Rules
- Each story completable in one context window
- Ordered by dependency (earlier stories don't depend on later ones)
- Every story has "Typecheck passes"
- UI stories have "Verify in browser using dev-browser skill"

---

## Output

1. **`prd.json`** — The merged PRD in phased JSON format
2. **`tasks/prd-[feature-name].md`** — The merged PRD in markdown (for human reading)
3. Show the user a summary of:
   - How many phases and stories were created
   - What was taken from each perspective
   - The phase structure

---

## Checklist

Before saving:

- [ ] Asked clarifying questions with lettered options
- [ ] Created two independent PRD perspectives
- [ ] Merged the best elements of both
- [ ] Grouped stories into logical phases (2-5 stories each)
- [ ] Stories are small and specific (one context window each)
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] Dependency ordering is correct
- [ ] Saved phased prd.json
- [ ] Saved markdown PRD to tasks/
