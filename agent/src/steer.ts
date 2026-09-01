import type { SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';

/**
 * Steering: getting a sentence into a build that is already running, without
 * stopping it.
 *
 * The mechanism is the SDK's streaming input mode. `query()` accepts an
 * `AsyncIterable<SDKUserMessage>` as its prompt; the CLI reads from it for as
 * long as it is open, and a message handed over while a turn is in flight goes
 * into the CLI's own command queue and is delivered at the next turn boundary
 * — the result of the running turn reports the backlog as `queued_turn_count`,
 * and the next turn follows with no further input. That is the whole contract
 * this queue is built on: nvime never interrupts the turn, it only decides what
 * the agent reads next.
 *
 * A steer is context for the build agent and nothing more. It cannot widen the
 * write boundary, reach the permission callback, or touch the review gate: it
 * arrives as an ordinary user turn inside the same `query()` whose options were
 * fixed when the build started.
 */

/** One steer, from the moment it is accepted to the moment the agent reads it. */
export interface SteerMessage {
  id: number;
  text: string;
  /**
   * Who sent it, as the control channel labelled them. Null when the sender did
   * not name itself; a viewer renders that as "an attached editor" rather than
   * as its own, because attributing someone else's steer to the reader is a lie.
   */
  origin: string | null;
}

/** How much one steer may carry. A whisper, not a second spec. */
export const MAX_STEER_CHARS = 4000;

/**
 * What a steered turn reads from. The turn owns the reading side; whoever holds
 * the concrete queue owns the writing side.
 */
export interface SteerSource {
  /** The next steer to hand over, or null once the turn should end. */
  next(): Promise<SteerMessage | null>;
  /** Called at the instant the SDK asks for that message, never before. */
  markDelivered(message: SteerMessage): void;
  /** Steers accepted but not yet handed over. */
  readonly pending: number;
}

/**
 * The turn's whole view of steering: read the next message, and decide when
 * there is nothing left to read. Ending the stream is the turn's call, not the
 * queue's — only the turn knows the agent has stopped asking for input.
 */
export interface SteerControl extends SteerSource {
  /**
   * A steer was handed over since the last result, so the turn that just ended
   * may or may not have been the last one — see `closeAfter`.
   */
  readonly awaitingTurn: boolean;
  /** Marks one result as seen: settles the debt, and cancels an armed close. */
  noteTurn(): void;
  /**
   * Closes after `ms`, unless a result arrives first. A steer delivered while
   * the window is open restarts it, so the window always measures from the last
   * thing the agent was handed.
   */
  closeAfter(ms: number, reason: string): void;
  close(reason: string): void;
  readonly closed: boolean;
}

export type SteerState = 'queued' | 'delivered';

export type SteerResult = { queued: true; id: number } | { queued: false; reason: string };

/**
 * The queue behind `big.steer`. Single reader (the turn), many writers (every
 * attached editor), and closing it is what ends the turn's input stream.
 */
export class SteerQueue implements SteerControl {
  readonly #onState: (message: SteerMessage, state: SteerState) => void;
  readonly #waiting: SteerMessage[] = [];
  #wake: ((message: SteerMessage | null) => void) | null = null;
  #closed: string | null = null;
  #closing: NodeJS.Timeout | null = null;
  /** The armed close's terms, kept so a delivery can restart the same window. */
  #window: { ms: number; reason: string } | null = null;
  #awaiting = false;
  #nextId = 1;

  /** @param onState records each transition — the event log renders both. */
  constructor(onState: (message: SteerMessage, state: SteerState) => void) {
    this.#onState = onState;
  }

  get pending(): number {
    return this.#waiting.length;
  }

  get closed(): boolean {
    return this.#closed !== null;
  }

  get awaitingTurn(): boolean {
    return this.#awaiting;
  }

  noteTurn(): void {
    this.#awaiting = false;
    this.#window = null;
    this.#cancelArmedClose();
  }

  closeAfter(ms: number, reason: string): void {
    if (this.#closed !== null) return;
    this.#window = { ms, reason };
    this.#arm();
  }

  /**
   * Accepts one steer, or says why it cannot be taken. Never throws: a refusal
   * is an answer the editor renders beside the message the user just typed.
   */
  push(text: string, origin: string | null = null): SteerResult {
    const trimmed = text.trim();
    if (trimmed === '') return { queued: false, reason: 'a steer needs some text' };
    if (trimmed.length > MAX_STEER_CHARS) {
      return { queued: false, reason: `a steer may be at most ${MAX_STEER_CHARS} characters` };
    }
    if (this.#closed !== null) return { queued: false, reason: this.#closed };
    const message: SteerMessage = { id: this.#nextId, text: trimmed, origin };
    this.#nextId += 1;
    this.#onState(message, 'queued');
    const wake = this.#wake;
    if (wake !== null) {
      // The turn is already asking for its next input, so hand it straight
      // over rather than parking it behind a reader that is not there.
      this.#wake = null;
      wake(message);
      return { queued: true, id: message.id };
    }
    this.#waiting.push(message);
    return { queued: true, id: message.id };
  }

  next(): Promise<SteerMessage | null> {
    const ready = this.#waiting.shift();
    if (ready !== undefined) return Promise.resolve(ready);
    if (this.#closed !== null) return Promise.resolve(null);
    return new Promise((resolve) => {
      this.#wake = resolve;
    });
  }

  markDelivered(message: SteerMessage): void {
    this.#awaiting = true;
    // A steer handed over inside an armed window gets the whole window of its
    // own. Letting the previous steer's timer close the stream under it refuses
    // every later steer with "the agent has stopped taking input" while the
    // build is still running — nvime blaming the agent for its own timer.
    if (this.#window !== null) this.#arm();
    this.#onState(message, 'delivered');
  }

  /**
   * Ends the turn's input stream. Whatever is still waiting is handed over
   * first — a steer this queue told the user was accepted is never dropped —
   * so the caller closes only once it has decided nothing is pending.
   */
  close(reason: string): void {
    if (this.#closed !== null) return;
    this.#window = null;
    this.#cancelArmedClose();
    this.#closed = reason;
    const wake = this.#wake;
    if (wake !== null) {
      this.#wake = null;
      wake(this.#waiting.shift() ?? null);
    }
  }

  /** (Re)starts the armed close from now, on the window's own terms. */
  #arm(): void {
    this.#cancelArmedClose();
    const window = this.#window;
    if (window === null) return;
    // Unreferenced: an armed close must never be the reason a runner outlives
    // the build it was running.
    this.#closing = setTimeout(() => {
      this.#closing = null;
      this.close(window.reason);
    }, window.ms);
    this.#closing.unref();
  }

  #cancelArmedClose(): void {
    if (this.#closing === null) return;
    clearTimeout(this.#closing);
    this.#closing = null;
  }
}

/**
 * The prompt a steerable turn runs on: the opening message, then every steer as
 * it arrives, until the source closes.
 *
 * `markDelivered` fires just before the yield, which is the honest moment: the
 * generator is only resumed when the SDK's input reader has asked for the next
 * message, so being asked for it IS the handover.
 */
export async function* steeredPrompt(opening: string, source: SteerSource): AsyncGenerator<SDKUserMessage> {
  yield userTurn(opening);
  for (;;) {
    const next = await source.next();
    if (next === null) return;
    source.markDelivered(next);
    yield userTurn(next.text);
  }
}

function userTurn(text: string): SDKUserMessage {
  return {
    type: 'user',
    message: { role: 'user', content: text },
    parent_tool_use_id: null,
  } as SDKUserMessage;
}
