/**
 * The minimum rubien-cli build this server requires. Equals the release build
 * that first shipped `grep`. Bump only when a future server release genuinely
 * needs a newer CLI feature; the released CLI's build must always be >= this
 * value.
 */
export const MIN_CLI_BUILD = 21;

export interface CliVersion {
  version: string;
  build: number;
}

export interface GuardResult {
  ok: boolean;
  message?: string;
}

const RELEASES = "https://github.com/devzhk/Rubien-releases/releases";

/** Pure decision: is the discovered CLI new enough? `info` is null when the
 *  CLI has no `version` subcommand (i.e. predates this mechanism). */
export function evaluateCliVersion(
  info: CliVersion | null,
  minBuild: number,
): GuardResult {
  if (info === null) {
    return {
      ok: false,
      message:
        `rubien-mcp-server: cannot determine rubien-cli version ` +
        `(your rubien-cli predates the 'version' command). ` +
        `Update Rubien.app (Mac) or download a newer rubien-cli from ${RELEASES} (Linux).`,
    };
  }
  if (info.build < minBuild) {
    return {
      ok: false,
      message:
        `rubien-mcp-server: installed rubien-cli is build ${info.build}, ` +
        `but this server needs build >= ${minBuild}. ` +
        `Update Rubien.app (Mac) or download a newer rubien-cli from ${RELEASES} (Linux).`,
    };
  }
  return { ok: true };
}
