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
- `SPC o n` — new task; complete a model from pi's `enabledModels` (empty
  uses pi's default). Settings come from `~/.pi/agent/settings.json`, or
  `$PI_CODING_AGENT_DIR/settings.json` when set. You can also enter another
  pi model pattern, including a thinking suffix such as `:high`.
- In any pilish session: ask the agent to hand work off as a task. Ask for a
  specific model to have `spawn_task` set its optional `model` parameter;
  otherwise it uses pi's default, not the caller's model.

Lisp callers can pass `:model` to `agent-tasks-spawn`, for example:

```elisp
(agent-tasks-spawn :name "review-login" :prompt "Review the login code..."
                   :cwd "/path/to/repo/"
                   :model "claude-bridge/claude-opus-5-5:high")
```

The dashboard's Model column shows the requested pattern, or `default`.
The selection is persisted with the task and reapplied when it is resumed,
including when a missing session file requires starting fresh. Pinned
resumes use pi's `--session` and `--model` together, so the task's model wins
if the saved session selected a different one. Older tasks without a model
retain their normal pi resume behavior.

An unknown or unavailable model is reported to the caller before any prompt
is sent. As with other spawn failures, a worktree/branch already created is
left in place; the error gives its path. The failed pi session is stopped.

## Develop

`make test` runs the ERT, extension and install tests.  Design and plan are in
`docs/plans/`.
