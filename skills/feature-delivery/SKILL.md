---
name: feature-delivery
description: Plan and land non-trivial feature work from a TODO, design, or review plan by saving an execution plan first, using gpt-5.3-codex subagents for implementation lanes, then running a two-subagent review-and-fix closure pass. Use for future feature development in this repo when the user asks to plan, upgrade, implement TODOs, open subagents, or use review-and-fix before final validation.
---

# Feature Delivery

Use this skill for feature development that should be handled as a planned delivery rather than a quick patch.

## Required Inputs

- A source of truth: TODO doc, design doc, review doc, issue statement, or user-provided feature request.
- The current repo state: inspect `git status --short`, relevant diffs, and relevant files before assuming the plan is current.
- If subagents are requested but no subagent tool is already visible, search for the multi-agent/subagent tool first.

## Workflow

### 1) Scope the Feature

- Read the source plan and extract the exact TODO ids or feature goals.
- Confirm the live code still matches the assumptions in the plan.
- Identify owned write scopes and likely tests before coding.
- Preserve any dirty user work. Do not revert unrelated changes.

For `js-runtime/ejs`, keep these boundaries in scope decisions:

- Root `platform/*` remains generic.
- WinterTC and optional modules such as `modules/fs` remain add-ons.
- Avoid public ABI growth unless the feature explicitly requires it.
- Keep test-only hooks behind `#ifdef EJS_TEST` or equivalent build gates.

### 2) Save an Execution Plan Before Coding

Create or update a concise Markdown plan under `docs/` before implementation. Include:

- source TODOs or feature ids,
- target behavior,
- files likely to change,
- implementation lanes,
- regression tests,
- verification matrix,
- evidence log section for commands and results.

Do not start code edits until this plan exists unless the user explicitly asks for a one-shot patch.

### 3) Run Baseline Verification

- Run the smallest meaningful baseline build/test command for the touched area.
- If baseline is already red, record the exact failure in the execution plan and avoid mixing baseline failures with feature regressions.
- If a required test needs network, localhost sockets, GUI, or restricted filesystem access and sandboxing blocks it, request escalation with the exact command.

### 4) Use Implementation Subagents

When the user asks to open subagents, spawn implementation lanes with model `gpt-5.3-codex`.

Prefer non-overlapping write scopes:

- one subagent per TODO, module, or behavior lane,
- explicit owned files and forbidden files,
- clear required tests and expected output,
- instruction to avoid destructive git operations.

If scopes overlap, still let subagents explore independently, but integrate changes serially in the main worktree. The main agent owns final conflict resolution, coding consistency, and test selection.

Implementation prompt skeleton:

```text
使用 gpt-5.3-codex 独立实现 <lane name>。
源计划：<doc path and TODO id>
目标行为：<expected behavior>
允许修改：<file/module scope>
不要修改：<out-of-scope files>
必须补充/更新测试：<test targets>
验证命令：<commands>
返回：变更摘要、风险、已运行命令。不要做 destructive git 操作。
```

Close or otherwise finish every subagent session before final response.

### 5) Integrate and Test

- Apply the smallest coherent implementation in the main worktree.
- Add targeted regressions for the exact new behavior or bug class.
- Run targeted build/test commands after each meaningful lane.
- Update the execution plan evidence log with command results.

When adding test hooks, also verify production/test separation:

```sh
EJS_TEST=OFF <production build command>
nm -g <built libraries> | rg '<test hook names>' || true
```

The expected result for the symbol scan is no test-only public symbols.

### 6) Run Double Review Closure

Use `review-and-fix` style review after the implementation is integrated.

Run two independent review subagents with no cross-contamination:

- model: `gpt-5.4,gpt-5.3-codex-spark`,
- no code edits,
- findings only,
- include severity, file, line, impact, and minimal fix,
- focus on correctness, regressions, tests, ABI/layering, lifecycle, and concurrency.

Review prompt skeleton:

```text
独立 review，本轮不要参考其他 agent 的结论，也不要改代码。
请审查当前实现是否完整落地 <feature/TODO ids>。
重点检查：正确性、回归测试、ABI/分层、生命周期/并发、错误处理。
只输出真实问题：severity、file:line、影响、最小修复建议。
```

Reconcile both reviews:

- fix all confirmed P0/P1/P2 issues when feasible,
- add or adjust tests for each fixed issue,
- document rejected findings only when there is concrete code evidence,
- rerun targeted tests and a final focused regression bundle.

### 7) Finalize

Before final response:

- Run `git diff --check`.
- Run final focused verification for all touched areas.
- Confirm no necessary subagent sessions are still running.
- Update the execution plan status/evidence.

Final response should include:

- implemented TODOs/features,
- review findings fixed or rejected,
- changed high-level areas,
- verification commands and outcomes,
- any remaining risks or blocked checks.

## Guardrails

- Use `rg`/`rg --files` for search and `apply_patch` for manual edits.
- Keep changes scoped to the feature and tests needed to prove it.
- Do not hide failed tests behind broad green smoke tests.
- Do not run destructive git commands unless the user explicitly requested them.
- Do not preserve subagent output blindly; the main agent must reconcile it against the live tree.
