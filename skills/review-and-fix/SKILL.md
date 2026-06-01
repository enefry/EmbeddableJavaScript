---
name: review-and-fix
description: Convert a review document (for example docs/full_review.md) into an itemized fix-and-verify workflow with strict per-issue execution. Use when a user asks to summarize review findings, save a fix plan to Markdown first, then fix items one by one with two independent subagent reviews before each implementation and targeted regression validation.
---

# Full Review Double Subagent Fix

## Overview

Turn a review report into a deterministic execution loop:
1) save the fix plan to Markdown, 2) review each item with two independent subagents, 3) reconcile and implement minimal changes, 4) add regression tests, 5) validate and record status.

## Workflow

### 1) Parse and scope findings

- Extract issue id, severity, file path, and expected behavior from the review document.
- Confirm whether each finding is pending or already fixed in the current tree.
- Keep scope issue-by-issue. Do not mix unrelated cleanup into the same step.

### 2) Save fix plan before coding

- Create or refresh a plan Markdown file first (for example `docs/fix_plan_from_full_review.md`).
- Record for each issue:
  - goal,
  - minimal code-change proposal,
  - regression test proposal,
  - verification command.
- Commit to a repair order (build gates first, then lifecycle/concurrency, then module-specific issues).

### 3) Run the per-issue execution loop

For each issue, run this sequence strictly:

1. Draft a minimal fix proposal locally.
2. Send the same problem statement to two subagents independently.
3. Collect both outputs without cross-contaminating context.
4. Reconcile into one decision:
   - choose the shared conclusion when both agree,
   - choose the safer, smaller-change option when they differ.
5. Implement the fix.
6. Add or update regression tests that target the exact failure mode.
7. Run only the relevant build/test commands.
8. Update plan status and evidence.

Use a prompt structure like:

```text
独立 review #<id>（不要参考其他 agent 结论）：
问题：<one-paragraph issue statement>
请给出：
1) 最小安全修复方案；
2) 需要新增/调整的测试点；
3) 兼容性风险。
只返回建议，不要改代码。
```

### 4) Validate closure

- Execute targeted tests for every modified area.
- Run a final focused `ctest -R '<targets>' --output-on-failure` pass.
- Report issue-to-change mapping with file paths and test evidence.

## Guardrails

- Preserve behavior boundaries unless the issue explicitly requires a behavior change.
- Preserve public ABI and cross-platform layering constraints.
- Avoid destructive git operations.
- Mark an item as unresolved only with concrete reproduction or blocker evidence.
- Keep review source documents unchanged unless the user asks to edit them.

## Deliverables

- Updated plan Markdown with per-issue status.
- Code changes and regression tests for each closed issue.
- A concise final summary including:
  - fixed ids,
  - changed files,
  - verification commands and results,
  - remaining risks.
