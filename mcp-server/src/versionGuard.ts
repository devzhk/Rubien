import { probeCliVersion, type CliProbe } from "./cli.js";

/**
 * The minimum rubien-cli build this server requires. Equals the build that
 * first shipped `stats`, which backs `rubien_reading_activity` in the 0.3.1
 * catalog. Bump only when a future server release
 * genuinely needs a newer CLI feature; the released CLI's build must always
 * be >= this value.
 */
export const MIN_CLI_BUILD = 28;

export interface CliVersion {
  version: string;
  build: number;
}

export type GuardResult =
  | { ok: true; info?: CliVersion }
  | { ok: false; message: string };

const RELEASES = "https://github.com/devzhk/Rubien-releases/releases";
const UPDATE_HINT = `Update Rubien.app (Mac) or download a newer rubien-cli from ${RELEASES} (Linux).`;

/** When rubien-cli came from $RUBIEN_CLI, "update the app" is dead advice —
 *  the override wins no matter what is installed. */
function overrideHint(probe: CliProbe): string {
  return probe.envOverride
    ? ` Note: rubien-cli is resolved from your RUBIEN_CLI override — point it ` +
      `at a newer binary, or unset it to use the one bundled with Rubien.app.`
    : "";
}

/** Pure decision: turn a CLI probe outcome into a verdict + user-facing
 *  message. Messages must say what to DO — in stdio mode they are returned
 *  as tool-call text, the only surface Claude Desktop users ever see. */
export function evaluateCliProbe(
  probe: CliProbe,
  minBuild: number,
): GuardResult {
  switch (probe.kind) {
    case "ok":
      if (probe.info.build < minBuild) {
        return {
          ok: false,
          message:
            `rubien-mcp-server: installed rubien-cli is build ${probe.info.build}, ` +
            `but this server needs build >= ${minBuild}. ${UPDATE_HINT}` +
            overrideHint(probe),
        };
      }
      return { ok: true, info: probe.info };
    case "not-found":
      return {
        ok: false,
        message:
          `rubien-mcp-server: rubien-cli not found (${probe.detail}). ` +
          `Install Rubien.app (Mac) — the CLI ships inside it — or download ` +
          `rubien-cli from ${RELEASES} and set RUBIEN_CLI to its path (Linux).` +
          overrideHint(probe),
      };
    case "timeout":
      return {
        ok: false,
        message:
          `rubien-mcp-server: rubien-cli at ${probe.path} did not answer ` +
          `'version' within ${Math.round(probe.timeoutMs / 1000)}s. This can ` +
          `happen on the first launch after a reboot — retry in a moment. ` +
          `If it persists, reinstall Rubien.app (Mac) or check the binary (Linux).` +
          overrideHint(probe),
      };
    case "no-version":
      // Reachable both by a genuinely old CLI (no `version` subcommand) and
      // by a binary that ran but failed (crash, EACCES, garbage output) —
      // don't claim to know which.
      return {
        ok: false,
        message:
          `rubien-mcp-server: the binary at ${probe.path} did not report a ` +
          `version — it either predates the 'version' command or is broken. ` +
          `${UPDATE_HINT}` + overrideHint(probe),
      };
  }
}

let compatible = false;
let inFlight: Promise<GuardResult> | null = null;

/**
 * Probe-and-evaluate with success caching: once a compatible CLI is seen the
 * check short-circuits for the life of the process; failures are never
 * cached, so every failing tool call re-probes. Updating Rubien.app
 * mid-session therefore recovers on the next call — important because
 * Claude Desktop only respawns MCP servers when the app itself relaunches.
 *
 * Concurrent callers share one in-flight probe (the startup log probe and a
 * first tool call routinely race, and a degraded server can get a burst of
 * calls) — without collapsing recovery: the shared promise is dropped once
 * settled, so the next call after a failure re-probes.
 */
export async function ensureCliCompatible(): Promise<GuardResult> {
  if (compatible) return { ok: true };
  if (!inFlight) {
    inFlight = (async () => {
      const verdict = evaluateCliProbe(await probeCliVersion(), MIN_CLI_BUILD);
      if (verdict.ok) compatible = true;
      return verdict;
    })().finally(() => {
      inFlight = null;
    });
  }
  return inFlight;
}
