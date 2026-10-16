# agent-tasks

Spawn pilish sessions into their own git worktree and Spacemacs layout, from
Emacs or from pi's `spawn_task` tool, and manage them from a dashboard.

## New machine

1. Pull `~/.spacemacs.d`; `config.org` loads this directory.
2. Run `./install.sh` (or `make install`) to link the pi extension.
3. Restart Emacs, then start a new pi session.

## Use

- `SPC o a` — dashboard: `RET` switch/resume, `R` resume all, `m` magit,
  `+` new task, `^` parent, `d` close, `gr` refresh, `q` quit.  Without evil,
  `k` also closes and `g` refreshes.
- `SPC o n` — new task.
- In any pilish session: ask the agent to hand work off as a task.

## Develop

`make test` runs the ERT, extension and install tests.  Design and plan are in
`docs/plans/`.
