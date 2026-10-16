/**
 * Pure helpers for the spawn_task extension: build the emacsclient form and
 * decode Emacs's reply.
 */

export type Spawned = {
	ok: true;
	task: string;
	layout: string;
	worktree: string;
	branch: string;
	base: string;
	baseFellBack: boolean;
};

export type Failed = { ok: false; error: string };

export type Reply = Spawned | Failed;

/** Quote S as an Emacs Lisp string literal. */
function elispString(s: string): string {
	return `"${s.replace(/[\\"]/g, (c) => `\\${c}`)}"`;
}

/** Return the form that spawns the task described by the JSON request FILE. */
export function buildForm(file: string): string {
	return `(agent-tasks-spawn-from-file ${elispString(file)})`;
}

/**
 * Decode the result of `emacsclient -e`.  Emacs returns a JSON string, which
 * emacsclient prints as a Lisp string, so it is parsed twice.
 */
export function parseReply(code: number, stdout: string, stderr: string): Reply {
	const output = `${stdout}${stderr}`.trim();
	if (code !== 0) {
		const elispError = output.match(/\*ERROR\*: (.*)/);
		if (elispError) {
			const hint = /agent-tasks-spawn-from-file/.test(elispError[1])
				? " (is agent-tasks loaded in Emacs?)"
				: "";
			return { ok: false, error: `Emacs error: ${elispError[1]}${hint}` };
		}
		return { ok: false, error: `Emacs server not reachable: ${output}` };
	}
	let reply: unknown;
	try {
		reply = JSON.parse(JSON.parse(stdout.trim()));
	} catch {
		return { ok: false, error: `Unexpected reply from Emacs: ${output}` };
	}
	const r = reply as Record<string, unknown>;
	if (typeof r.error === "string") return { ok: false, error: r.error };
	return {
		ok: true,
		task: String(r.task),
		layout: String(r.layout),
		worktree: String(r.worktree),
		branch: String(r.branch),
		base: String(r.base),
		baseFellBack: r.baseFellBack === true,
	};
}

/** Describe a spawned task for the model. */
export function formatSpawned(s: Spawned): string {
	const fallback = s.baseFellBack ? " (no main branch; fell back)" : "";
	return [
		`Spawned task ${s.task}; it is now running in its own pilish session.`,
		`Layout: ${s.layout}`,
		`Worktree: ${s.worktree}`,
		`Branch: ${s.branch} from ${s.base}${fallback}`,
	].join("\n");
}
