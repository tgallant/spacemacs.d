/**
 * spawn_task: start a new pilish session for a task in its own git worktree
 * and Emacs layout.  The work is done by agent-tasks.el in the running
 * Emacs, reached through emacsclient.
 */

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { buildForm, formatSpawned, parseReply } from "./lib.ts";

export default function (pi: ExtensionAPI) {
	pi.registerTool(
		defineTool({
			name: "spawn_task",
			label: "Spawn task",
			description: [
				"Start a separate agent session that works on a task in its own git worktree,",
				"branch and Emacs layout. Returns immediately; the task runs in the background",
				"and the user monitors it from Emacs. Use it only when the user asks to hand",
				"work off as a task.",
				"",
				"- prompt: the new session has none of this conversation's context. Write a",
				"  self-contained prompt with the goal, relevant files, constraints and how to",
				"  verify the work.",
				"- name: short kebab-case; it becomes the branch, the layout and the worktree",
				"  directory suffix.",
				"- repo: omit for the current repository. Otherwise a project name such as",
				"  'tmd' or an absolute path.",
				"- base: omit unless the user named a branch to start from (default main).",
			].join("\n"),
			parameters: Type.Object({
				name: Type.String({ description: "Short kebab-case task name, e.g. fix-login-timeout" }),
				prompt: Type.String({ description: "Self-contained instructions for the new session" }),
				repo: Type.Optional(Type.String({ description: "Project name or absolute path; omit for current repo" })),
				base: Type.Optional(Type.String({ description: "Branch to start from; omit unless the user named one" })),
			}),

			async execute(_toolCallId, params, signal, _onUpdate, ctx) {
				const dir = mkdtempSync(join(tmpdir(), "spawn-task-"));
				const file = join(dir, "request.json");
				try {
					writeFileSync(
						file,
						JSON.stringify({
							...params,
							cwd: ctx.cwd,
							parentSession: ctx.sessionManager.getSessionFile() ?? null,
						}),
					);
					const result = await pi.exec("emacsclient", ["-e", buildForm(file)], {
						signal,
						timeout: 60_000,
					});
					const reply = parseReply(result.code, result.stdout, result.stderr);
					if (!reply.ok) throw new Error(reply.error);
					return {
						content: [{ type: "text", text: formatSpawned(reply) }],
						details: reply,
					};
				} finally {
					rmSync(dir, { recursive: true, force: true });
				}
			},
		}),
	);
}
