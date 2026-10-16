# agent-tasks — design

Spawn pilish agent sessions into their own git worktree and Spacemacs
layout, from Emacs or from any running pi session, and monitor them from one
dashboard.

## Goals

- From any pilish session (or `M-x`), submit a task: a new worktree, a new
  layout and a new pilish session are created, the prompt is sent, and the
  call returns immediately.  The current layout and windows are untouched.
- Any spawned session can spawn further tasks.
- A dashboard lists tasks and live pilish sessions with their agent status
  and lets you switch, inspect, close and resume them.
- Tasks survive an Emacs restart (lazily resumed).

## Non-goals (v1)

- Rollback of partially created tasks.
- Persisting sessions that were not created through agent-tasks.
- OS-level notifications.

## Components

Everything lives in `~/.spacemacs.d/agent-tasks/`: `agent-tasks.el` (added
to the load-path by `config.org`) and the pi extension in `pi/spawn-task/`,
which `install.sh` symlinks into `~/.pi/agent/extensions/`.
`agent-tasks-mode` starts the Emacs server, which `spawn_task` needs.

1. **pilish adapter** — the only code touching pilish: start a session, send
   a prompt (via the public `pilish-send` in the input buffer), read status,
   read the session file, kill a session, resume from a session file
   (`pilish-open-session-file`).
2. **git layer** — repo resolution, base resolution, worktree creation.
3. **task core** — registry, spawn, guardrails, persistence.
4. **dashboard** — `tabulated-list-mode`, poll timer, notifications,
   mode-line counter.

## Spawn

`agent-tasks-spawn` (plist: `:name :prompt :repo :base :cwd :parent-session`):

1. Resolve repo: `:repo` as an absolute/`~` path, else a projectile known
   project matched by directory basename (worktree directories excluded);
   if absent, the main checkout of `:cwd`
   (`git rev-parse --path-format=absolute --git-common-dir`, parent dir).
   Ambiguous or unknown names are errors listing candidates.
2. Resolve base: `:base` if given (must exist), else `main`, else the target of
   `refs/remotes/origin/HEAD`, else `master`.  Otherwise an error listing the
   branches that exist.  Record whether a fallback was used.
3. Validate name: kebab-case `[a-z0-9][a-z0-9-]*`; reject if a layout, local
   branch or worktree directory with that name already exists.
4. Guardrails: refuse if the parent's depth + 1 > `agent-tasks-max-depth`
   (default 3) or live tasks >= `agent-tasks-max-live` (default 8).
5. `git worktree add -b NAME <repo>-NAME BASE`.
6. `persp-add-new NAME` (no switch).
7. Start pilish in the worktree, add chat+input buffers to the layout, send
   the prompt.
8. Register, persist, return
   `(:task :layout :worktree :branch :base :base-fell-back)`.

The pilish window split is created the first time the layout is activated
(`persp-activated-functions`).  No rollback: errors after step 5 say what was
created.

Parent: the chat buffer whose session file equals `:parent-session`; its task
name, else the name of a layout containing it, else nil.  Depth is parent depth
+ 1 (untracked parents have depth 0).

## pi extension

Tool `spawn_task(name, prompt, repo?, base?)`.  Writes the request plus
`cwd` and `parentSession` to a temp JSON file and runs
`emacsclient -e '(agent-tasks-spawn-from-file "FILE")'` without a shell.
Emacs replies with a JSON string (decoded with two `JSON.parse` calls);
`{"error": ...}` replies and non-zero exits become tool errors.  The tool
description requires a self-contained prompt and says to set `base` only if the
user named a branch.

## Status

| Status        | Meaning                                                |
|---------------|--------------------------------------------------------|
| `working`     | pilish status `sending`, `streaming` or `compacting`   |
| `idle`        | waiting, already seen                                  |
| `done`        | went working → idle and the layout has not been visited |
| `exited`      | buffer live, pi process dead                           |
| `dormant`     | persisted, no live session (`dormant (interrupted)` if last status was working) |
| `missing`     | persisted, worktree directory gone                     |

A 2 s timer polls statuses, marks `done` on working → idle, messages
`agent-tasks: NAME finished`, updates `global-mode-string` (`⚙N ●M`), redraws
the dashboard if visible and persists on change.  Visiting a layout clears
`done`.

## Dashboard (`SPC o a`)

Rows: registry tasks plus untracked live pilish chat buffers.  Columns:
Task | Status | Repo | Branch (base) | Age | Parent.

Keys: `RET` switch (resumes dormant tasks), `R` resume all dormant,
`m` magit-status, `+` new task, `^` parent, `k` close, `g` refresh.

Close: kill session and layout, then ask whether to remove the worktree and
delete the branch.  If dirty or unmerged into its base, the prompt says so and
uses `yes-or-no-p`.

## Persistence

`~/.emacs.d/.cache/agent-tasks.eld`: a list of plists
`(:name :repo :worktree :branch :base :parent :depth :created :prompt
:session-file :last-status)`.  Written atomically (temp + rename) on spawn,
close, status change and session-file change.  Loaded at startup; tasks are
resumed lazily.

## Config changes

Remove `start-tmux-window`, `my/create-tmux-window`, `my/new-worktree-session`
and the `SPC o c` / `SPC o n` bindings.  Add `(require 'agent-tasks)`,
`SPC o a` → dashboard, `SPC o n` → new task.

## Changes found during implementation

- A turn shorter than the poll interval was missed.  A variable watcher on
  `pilish--status` latches activity and triggers an immediate poll; it never
  signals, because it runs inside pilish's own `setq`.
- A spawned agent did not know its branch was made for it and stopped to ask.
  `agent-tasks-prompt-preamble` now names the worktree, branch and base.
- pi-superpowers-plus writes `.pi/superpowers-state.json` in every worktree, so
  every task looked dirty.  `agent-tasks-ignored-changes` (default `.pi/`).
- A new layout starts with the previous layout's windows and pilish's input
  window is dedicated; the first visit un-dedicates the remaining window
  before showing the task.
- Under evil the dashboard opened in motion state, whose RET, k, g, + and ^
  shadowed the mode's keys.  The keys are now also bound for motion state;
  close is on d there because j/k stay navigation.
- Killing a buffer of another layout prompts in persp-mode; deliberate kills
  bind `persp-kill-foreign-buffer-behaviour` to `kill`.

## Testing

ERT (batch, `emacs -Q` with persp-mode on the load-path) against throwaway git
repos; the pilish adapter is stubbed.  `node --test` for the extension's pure
logic.  Manual end-to-end checklist against the live Emacs.
