#!/bin/sh
# Install agent-tasks on this machine.
#
# The Emacs side is loaded from config.org, so pulling ~/.spacemacs.d is
# enough for it.  This links the pi extension into pi's extensions
# directory and checks the tools agent-tasks needs.  Safe to re-run.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src="$here/pi/spawn-task"
ext_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions"
dst="$ext_dir/spawn-task"

mkdir -p "$ext_dir"
if [ -L "$dst" ]; then
	current=$(readlink "$dst")
	if [ "$current" = "$src" ]; then
		echo "pi extension already linked: $dst"
	else
		ln -sfn "$src" "$dst"
		echo "pi extension repointed: $dst -> $src (was $current)"
	fi
elif [ -e "$dst" ]; then
	echo "error: $dst exists and is not a symlink; move it away and re-run" >&2
	exit 1
else
	ln -s "$src" "$dst"
	echo "pi extension linked: $dst -> $src"
fi

warn() { echo "warning: $*" >&2; }

for tool in git emacsclient pi; do
	command -v "$tool" > /dev/null 2>&1 || warn "$tool not found on PATH"
done

if command -v emacsclient > /dev/null 2>&1; then
	if loaded=$(emacsclient -e "(featurep 'agent-tasks)" 2> /dev/null); then
		[ "$loaded" = t ] ||
			warn "Emacs is running without agent-tasks; restart it or evaluate its config.org block"
	else
		echo "Emacs server not running; agent-tasks-mode starts it when Emacs loads your config"
	fi
fi

echo "Start a new pi session (or /reload) to get the spawn_task tool."
