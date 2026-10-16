# agent-tasks Implementation Plan

> **REQUIRED SUB-SKILL:** Use the executing-plans skill to implement this plan task-by-task.

**Goal:** Spawn pilish sessions into new worktrees + layouts from Emacs or pi,
and manage them from a dashboard.

**Architecture:** One Emacs Lisp file with four sections (pilish adapter, git
layer, task core, dashboard) plus a thin pi extension that calls
`emacsclient`.  See `2026-10-14-agent-tasks-design.md`.

**Tech Stack:** Emacs 30 / ERT, persp-mode, pilish, git CLI, pi extension API
(TypeScript run by node 26 / pi).

**Test commands:**

- Elisp: `make test` →
  `emacs -Q --batch -L . -L $(PERSP) -l test/agent-tasks-test.el -f ert-run-tests-batch-and-exit`
- Extension: `node --test pi/spawn-task/`

Grounded facts (verified 2026-10-14 against the live setup):

- `persp-get-by-name` returns `:nil` when missing; use `persp-with-name-exists-p`.
- `persp-add-new NAME` does not switch; `persp-add-buffer BUFS PERSP nil nil`
  adds without switching; `persp-kill NAME t` keeps buffers.
- `persp-activated-functions` receive `(type frame-or-window persp)`.
- `pilish--setup-session DIR` starts a session without displaying it; sending
  via `pilish-send` in the input buffer works and is queued until ready.
- `(plist-get pilish--state :session-file)` is set once `get_state` returns.
- `pilish-quit-without-confirmation` bound to t + `kill-buffer` kills the
  session and its input buffer.
- `pilish-open-session-file FILE` resumes with history and displays buffers
  in the selected window.
- pilish passes `--approve` in RPC mode, so no trust prompt.
- `refs/remotes/origin/HEAD` is absent in several local repos (e.g. arkb).
- emacsclient prints a returned string as a Lisp string; `JSON.parse` twice.
  Elisp errors print `*ERROR*: msg` and exit 1.

---

### Task 1: git layer

**TDD scenario:** New feature — full TDD cycle.

**Files:** Create `agent-tasks.el`, `test/agent-tasks-test.el`, `Makefile`.

Tests (each against temp repos created by a `with-temp-repo` helper):

1. `agent-tasks--main-checkout` returns the repo root from the root, a subdir
   and a linked worktree.
2. `agent-tasks--resolve-base` returns `("main" . nil)` when main exists.
3. falls back to `master` with fell-back t.
4. falls back to origin/HEAD target before master.
5. explicit base that exists is returned unchanged; missing explicit base errors.
6. no candidate → error listing existing branches; unborn repo → error.
7. `agent-tasks--resolve-repo` accepts absolute and `~` paths (must be a git
   checkout), basenames from a supplied project list, errors on ambiguity
   (listing candidates) and unknown names, ignores worktree dirs.
8. `agent-tasks--create-worktree` creates `<repo>-<name>` on branch `name`
   from base.
9. `agent-tasks--validate-name` rejects bad syntax and existing branch /
   directory.

### Task 2: registry + persistence

**TDD scenario:** New feature.

Tests: task struct ⇄ plist round trip; save writes atomically and load reads
it back; load of a missing file yields nil; corrupt file yields nil with a
message.

### Task 3: spawn orchestration + guardrails

**TDD scenario:** New feature.  Adapter functions are stubbed with
`cl-letf`; persp-mode is real (batch).

Tests: spawn creates worktree, layout (current layout unchanged), registers
task, calls adapter start/send with the worktree and prompt, returns plist;
depth limit; live limit; duplicate name; parent resolution from session file;
`agent-tasks-spawn-from-file` returns JSON and returns `{"error":…}` on
failure.

Then live check of the real adapter against the user's Emacs with a throwaway
repo.

### Task 4: status + polling

**TDD scenario:** New feature.

Tests: `agent-tasks--derive-status` truth table; poll marks `done` on
working → idle and calls the notifier once; visiting the layout clears
`done`; mode-line string counts.

### Task 5: dashboard + close/resume

**TDD scenario:** New feature (entries function TDD; interactive commands
verified live).

Tests: `agent-tasks--entries` includes registry tasks and untracked pilish
buffers; dormant/missing rows from persisted tasks; close removes the task,
kills the layout and (when confirmed) removes the worktree and branch; dirty
check.

### Task 6: pi extension

**TDD scenario:** New feature.

Files: `pi/spawn-task/lib.ts`, `pi/spawn-task/lib.test.ts`,
`pi/spawn-task/index.ts`.  Tests: `buildForm` escapes the path;
`parseReply` handles success, `{"error"}`, `*ERROR*` output.  Then a real
`pi -p` run that calls the tool.

### Task 7: config wiring

Edit `~/.spacemacs.d/config.org`: remove tmux/gemini functions and bindings,
add the require and bindings.  Tangle-equivalent check: load config block in
live Emacs.

### Task 8: end-to-end

Spawn from the dashboard; spawn from a pi session (child); spawn into
another repo; arkb master fallback; close dirty task; persist → kill
session → resume dormant.
