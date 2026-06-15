/**
 * sentry-guard - OpenClaw plugin bridging Agentic Sentry
 *
 * Registers a `before_tool_call` handler that screens exec/shell tool
 * calls with Sentry's detection engine (via `sentryctl check --json`)
 * before they run on the host.
 *
 * Mode mapping (Sentry mode -> OpenClaw decision):
 *   safe command       -> no-op (invisible)
 *   audit              -> no-op, logged by sentryctl --log
 *   warn / dry-run     -> requireApproval (operator sees Sentry's reason)
 *   soft-block / hard  -> block (terminal, skips lower-priority handlers)
 *
 * Fail-safe: if sentryctl is missing or errors, the plugin does nothing,
 * leaving OpenClaw's own exec-approval policy fully in charge. It never
 * auto-approves.
 *
 * STATUS: experimental — written against the OpenClaw Plugin SDK docs
 * (before_tool_call contract); validate against your OpenClaw version.
 * Set SENTRY_REPO if the repo is not at the default path below.
 */

import { execFileSync } from "node:child_process";

const SENTRY_REPO =
  process.env.SENTRY_REPO ?? `${process.env.HOME}/agentic-sentry`;
const SENTRYCTL = `${SENTRY_REPO}/sentryctl`;

// Tool names whose params carry a host shell command.
const EXEC_TOOLS = new Set(["exec", "shell", "bash", "process"]);

type Verdict = { verdict: "safe" | "dangerous"; reason: string; mode: string };

function check(command: string, cwd: string): Verdict | null {
  try {
    const out = execFileSync(
      SENTRYCTL,
      ["check", "--json", "--log", "--component", "openclaw-plugin", "--cwd", cwd, "--", command],
      { encoding: "utf8", timeout: 10_000 },
    );
    return JSON.parse(out) as Verdict;
  } catch (err: unknown) {
    // Exit code 1 = dangerous verdict, still with JSON on stdout
    const stdout = (err as { stdout?: string })?.stdout;
    if (typeof stdout === "string" && stdout.trim().startsWith("{")) {
      try {
        return JSON.parse(stdout) as Verdict;
      } catch {
        return null;
      }
    }
    return null; // sentryctl missing/broken -> defer to OpenClaw's own policy
  }
}

export default definePluginEntry({
  id: "sentry-guard",
  register(api) {
    api.on(
      "before_tool_call",
      async (event, ctx) => {
        if (!EXEC_TOOLS.has(event.toolName)) return;

        const params = (event.params ?? {}) as Record<string, unknown>;
        const command =
          (params.command as string) ?? (params.cmd as string) ?? "";
        if (!command) return;
        const cwd = (params.cwd as string) ?? process.env.HOME ?? "/";

        const result = check(command, cwd);
        if (!result || result.verdict !== "dangerous") return;

        const reason = `Sentry (${result.mode} mode): ${result.reason}`;

        if (result.mode === "soft-block" || result.mode === "hard") {
          return { block: true, blockReason: reason };
        }
        if (result.mode === "warn" || result.mode === "dry-run") {
          return {
            requireApproval: {
              title: "Sentry flagged this command",
              description: reason,
              severity: "warning",
              timeoutBehavior: "deny",
            },
          };
        }
        // audit: already logged via --log; let it run
        return;
      },
      { priority: 10 },
    );
  },
});
