// Stable error contract, modeled after ego-browser's `ego-errors.ts`: every
// failure an agent can hit maps to a fixed `PEEKR_*` code. Agents branch on
// codes, not prose. Hard-stop codes must never be retried — the printed
// guidance tells the agent to stop and ask the user.

export const ErrorCodes = {
  spaceRequired: "PEEKR_SPACE_REQUIRED",
  sessionChanged: "PEEKR_SESSION_CHANGED",
  stalePage: "PEEKR_STALE_PAGE",
  targetNotOwned: "PEEKR_TARGET_NOT_OWNED",
  browserBusy: "PEEKR_BROWSER_BUSY",
  invalidArgument: "PEEKR_INVALID_ARGUMENT",
  bridgeRequired: "PEEKR_BRIDGE_REQUIRED",
  tabLimit: "PEEKR_TAB_LIMIT",
  /** agent.json missing or Agent access disabled in Peekr preferences. */
  agentAccessDisabled: "PEEKR_AGENT_ACCESS_DISABLED",
  /** Peekr not running, port stale, or the CDP endpoint refused us. */
  cdpUnavailable: "PEEKR_CDP_UNAVAILABLE",
  /** Referenced space id/name does not exist. */
  spaceNotFound: "PEEKR_SPACE_NOT_FOUND",
  /** The user took the space over — every browser op must stop. */
  spaceUserInControl: "PEEKR_SPACE_USER_IN_CONTROL",
  /** Space was closed/completed; create a new one for further work. */
  spaceInactive: "PEEKR_SPACE_INACTIVE",
  /** Browser op issued without any live page target. */
  noActiveTab: "PEEKR_NO_ACTIVE_TAB",
  /** @N ref absent from the most recent snapshot. */
  unknownRef: "PEEKR_UNKNOWN_REF",
  /** Page action failed (selector not found, navigation blocked, ...). */
  actionFailed: "PEEKR_ACTION_FAILED",
} as const;

export type ErrorCode = (typeof ErrorCodes)[keyof typeof ErrorCodes];

const HARD_STOP_CODES: ReadonlySet<string> = new Set([
  ErrorCodes.spaceUserInControl,
  ErrorCodes.agentAccessDisabled,
  ErrorCodes.spaceInactive,
  ErrorCodes.spaceRequired,
  ErrorCodes.sessionChanged,
  ErrorCodes.targetNotOwned,
  ErrorCodes.bridgeRequired,
  ErrorCodes.browserBusy,
]);

export class PeekrError extends Error {
  readonly code: ErrorCode | string;
  readonly data?: Record<string, unknown>;

  constructor(code: ErrorCode | string, message: string, data?: Record<string, unknown>) {
    super(message);
    this.name = "PeekrError";
    this.code = code;
    this.data = data;
  }

  /** ego-style hard stop: never retry; surface to the user and wait. */
  get hardStop(): boolean {
    return HARD_STOP_CODES.has(this.code);
  }

  /** Fixed recovery wording so agents behave the same everywhere. */
  get guidance(): string {
    if (this.code === ErrorCodes.spaceUserInControl) {
      return (
        "Hard stop: the user has taken over this space. Do not retry any browser " +
        "operation and do not take control back on your own. Tell the user what you " +
        "were doing, then wait for their explicit confirmation (e.g. \"continue\"); " +
        "only after it, resume with takeOverSpace(id)."
      );
    }
    if (this.code === ErrorCodes.agentAccessDisabled) {
      return (
        "Hard stop: Peekr's agent access is not enabled. Do not retry. Ask the user " +
        "to open Peekr → Preferences → Browser → Agent Access, enable it, relaunch " +
        "Peekr, then run this task again."
      );
    }
    if (this.code === ErrorCodes.spaceInactive) {
      return (
        "Hard stop: this task space was closed. Do not reuse it. Start a fresh " +
        "space with useOrCreateSpace(name) for any follow-up work."
      );
    }
    if (this.hardStop) {
      return "Hard stop: do not retry in this round. Resolve the reported cause before starting a new round; user ownership requires explicit confirmation.";
    }
    if (this.code === ErrorCodes.cdpUnavailable) {
      return "Connection lost: the last action may have taken effect. Inspect page state in a new round before continuing; do not automatically replay writes.";
    }
    return "Check the code and message, verify the page state, then fix the cause before continuing.";
  }

  toJSON(): Record<string, unknown> {
    return {
      ok: false,
      code: this.code,
      message: this.message,
      hard_stop: this.hardStop,
      guidance: this.guidance,
      ...(this.data ? { data: this.data } : {}),
    };
  }
}

export function isHardStopCode(code: string): boolean {
  return HARD_STOP_CODES.has(code);
}
