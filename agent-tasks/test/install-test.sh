#!/bin/sh
# Tests for install.sh, run against a throwaway PI_CODING_AGENT_DIR.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PI_CODING_AGENT_DIR="$tmp/agent"
link="$PI_CODING_AGENT_DIR/extensions/spawn-task"
fails=0

check() {
	if eval "$2"; then echo "ok - $1"; else echo "not ok - $1"; fails=$((fails + 1)); fi
}

"$here/install.sh" > "$tmp/out1" 2>&1
check "fresh install exits 0" "[ $? -eq 0 ]"
check "fresh install links the extension" "[ \"\$(readlink '$link')\" = '$here/pi/spawn-task' ]"

"$here/install.sh" > "$tmp/out2" 2>&1
check "re-running exits 0" "[ $? -eq 0 ]"
check "re-running reports the link is current" "grep -q 'already linked' '$tmp/out2'"

ln -sfn "$tmp/elsewhere" "$link"
"$here/install.sh" > "$tmp/out3" 2>&1
check "a stale link is repointed" "[ \"\$(readlink '$link')\" = '$here/pi/spawn-task' ]"
check "repointing is reported" "grep -q 'repointed' '$tmp/out3'"

rm "$link" && mkdir "$link"
"$here/install.sh" > "$tmp/out4" 2>&1
check "a real directory is refused" "[ $? -ne 0 ]"
check "a real directory is left alone" "[ -d '$link' ] && [ ! -L '$link' ]"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
