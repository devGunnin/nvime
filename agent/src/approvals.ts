/**
 * The asynchronous half of edit mode's permission policy: a tool the policy
 * will not auto-allow parks here while the editor asks the user, and the tool
 * call stays blocked until an answer arrives.
 *
 * Every exit denies except an explicit allow — timeout, cancelled run, closed
 * panel. A permission prompt has no deadline of its own inside the SDK, so a
 * gate that failed open (or simply never settled) would leave the model
 * holding a write nobody sanctioned.
 */

/**
 * How an ask ended. The editor renders a deny the user never saw differently
 * from one they typed, so the cause travels with the outcome rather than
 * being guessed at from `reason`'s wording.
 */
export type ApprovalCause = 'answered' | 'timeout' | 'aborted' | 'duplicate';

export interface ApprovalOutcome {
  allowed: boolean;
  cause: ApprovalCause;
  /** Why, in the words the editor shows when the answer was not a plain yes. */
  reason: string;
}

interface Waiting {
  settle: (outcome: ApprovalOutcome) => void;
  timer: NodeJS.Timeout;
}

export const DEFAULT_APPROVAL_TIMEOUT_MS = 60_000;

export class ApprovalGate {
  readonly #waiting = new Map<string, Waiting>();
  readonly #timeoutMs: number;

  constructor(timeoutMs: number = DEFAULT_APPROVAL_TIMEOUT_MS) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
      throw new Error('the approval gate needs a positive timeout');
    }
    this.#timeoutMs = timeoutMs;
  }

  /** Approvals still waiting for an answer. */
  get pending(): number {
    return this.#waiting.size;
  }

  /** Whether an ask with this id is still on the editor's screen. */
  isPending(approvalId: string): boolean {
    return this.#waiting.has(approvalId);
  }

  /**
   * Blocks until the editor answers `approvalId`, the deadline passes, or the
   * run aborts. Resolves exactly once.
   *
   * A duplicate id is refused rather than thrown: the throw escaped into the
   * SDK and failed the whole run with an opaque error, where the caller wants
   * the one tool call refused and the ask already on screen left alone.
   */
  request(approvalId: string, signal?: AbortSignal): Promise<ApprovalOutcome> {
    if (this.#waiting.has(approvalId)) {
      // Its own cause: the run is fine and the first ask is still on screen,
      // so the editor must not render this as an abort.
      return Promise.resolve({
        allowed: false,
        cause: 'duplicate',
        reason: `approval ${approvalId} is already pending`,
      });
    }
    if (signal?.aborted === true) {
      return Promise.resolve({ allowed: false, cause: 'aborted', reason: 'the run was cancelled' });
    }
    return new Promise<ApprovalOutcome>((resolve) => {
      const onAbort = (): void => {
        this.#settle(approvalId, { allowed: false, cause: 'aborted', reason: 'the run was cancelled' });
      };
      const settle = (outcome: ApprovalOutcome): void => {
        signal?.removeEventListener('abort', onAbort);
        resolve(outcome);
      };
      const timer = setTimeout(() => {
        this.#settle(approvalId, {
          allowed: false,
          cause: 'timeout',
          reason: `no answer from the editor within ${this.#timeoutMs}ms`,
        });
      }, this.#timeoutMs);
      this.#waiting.set(approvalId, { settle, timer });
      signal?.addEventListener('abort', onAbort, { once: true });
    });
  }

  /** Delivers the editor's answer. False when nothing was waiting on that id. */
  answer(approvalId: string, allowed: boolean): boolean {
    return this.#settle(approvalId, {
      allowed,
      cause: 'answered',
      reason: allowed ? 'allowed in the editor' : 'denied in the editor',
    });
  }

  /**
   * Denies one waiting approval without the editor answering — a finished or
   * cancelled run leaves none behind. False when nothing was waiting.
   */
  deny(approvalId: string, reason: string): boolean {
    return this.#settle(approvalId, { allowed: false, cause: 'aborted', reason });
  }

  #settle(approvalId: string, outcome: ApprovalOutcome): boolean {
    const waiting = this.#waiting.get(approvalId);
    if (waiting === undefined) return false;
    this.#waiting.delete(approvalId);
    clearTimeout(waiting.timer);
    waiting.settle(outcome);
    return true;
  }
}
