import assert from "node:assert/strict";
import { test } from "node:test";
import { buildForm, formatSpawned, parseReply } from "./lib.ts";

test("buildForm quotes the request path as an elisp string", () => {
	assert.equal(
		buildForm('/tmp/a "b"\\c.json'),
		'(agent-tasks-spawn-from-file "/tmp/a \\"b\\"\\\\c.json")',
	);
});

test("parseReply decodes the lisp-printed JSON of a spawned task", () => {
	// Exactly what emacsclient prints for a returned JSON string.
	const stdout =
		'"{\\"task\\":\\"feat\\",\\"layout\\":\\"feat\\",\\"worktree\\":\\"/r-feat/\\",' +
		'\\"branch\\":\\"feat\\",\\"base\\":\\"master\\",\\"baseFellBack\\":true}"\n';
	assert.deepEqual(parseReply(0, stdout, ""), {
		ok: true,
		task: "feat",
		layout: "feat",
		worktree: "/r-feat/",
		branch: "feat",
		base: "master",
		baseFellBack: true,
	});
});

test("parseReply retains an explicitly requested model", () => {
	const model = "openai-codex/gpt-6.1-sol:high";
	const reply = parseReply(0, JSON.stringify(JSON.stringify({
		task: "feat", layout: "feat", worktree: "/r-feat/", branch: "feat",
		base: "main", baseFellBack: false, model,
	})), "");
	assert.equal(reply.ok && reply.model, model);
	if (reply.ok) assert.match(formatSpawned(reply), /Model: openai-codex\/gpt-6\.1-sol:high/);
});

test("formatSpawned omits model when using pi's default", () => {
	assert.doesNotMatch(formatSpawned({
		ok: true, task: "feat", layout: "feat", worktree: "/r-feat/",
		branch: "feat", base: "main", baseFellBack: false,
	}), /Model:/);
});

test("parseReply returns the error of an error reply", () => {
	const stdout = '"{\\"error\\":\\"Ambiguous repo tmd; candidates: ~/a/tmd/, ~/b/tmd/\\"}"\n';
	assert.deepEqual(parseReply(0, stdout, ""), {
		ok: false,
		error: "Ambiguous repo tmd; candidates: ~/a/tmd/, ~/b/tmd/",
	});
});

test("parseReply reports elisp errors printed by emacsclient", () => {
	assert.deepEqual(parseReply(1, "", "*ERROR*: Symbol’s function definition is void: agent-tasks-spawn-from-file\n"), {
		ok: false,
		error:
			"Emacs error: Symbol’s function definition is void: agent-tasks-spawn-from-file " +
			"(is agent-tasks loaded in Emacs?)",
	});
});

test("parseReply reports an unreachable Emacs server", () => {
	const stderr =
		"emacsclient: can't find socket; have you started the server?\n" +
		'emacsclient: To start the server in Emacs, type "M-x server-start".\n';
	const reply = parseReply(1, "", stderr);
	assert.equal(reply.ok, false);
	assert.match((reply as { error: string }).error, /^Emacs server not reachable/);
});

test("parseReply rejects unparseable output", () => {
	const reply = parseReply(0, "t\n", "");
	assert.equal(reply.ok, false);
	assert.match((reply as { error: string }).error, /Unexpected reply from Emacs: t/);
});

test("formatSpawned mentions a base fallback", () => {
	const text = formatSpawned({
		ok: true,
		task: "feat",
		layout: "feat",
		worktree: "/r-feat/",
		branch: "feat",
		base: "master",
		baseFellBack: true,
	});
	assert.match(text, /Spawned task feat/);
	assert.match(text, /\/r-feat\//);
	assert.match(text, /from master \(no main branch; fell back\)/);
});
