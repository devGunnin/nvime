import type { DebugLog } from './debuglog.js';
import {
  ProtocolError,
  parseRequest,
  rpcError,
  type OutgoingFrame,
  type RequestFrame,
} from './protocol.js';

export type Handler = (id: number, params: Record<string, unknown>) => Promise<unknown>;
export type WriteFrame = (frame: OutgoingFrame) => void;

/**
 * Routes incoming request lines to handlers and guarantees exactly one
 * response per well-formed request. Handlers run concurrently on purpose:
 * `chat.cancel` has to be serviced while its `chat.send` is still streaming.
 */
export class Dispatcher {
  readonly #handlers = new Map<string, Handler>();
  readonly #write: WriteFrame;
  /** The shared debug log, when one is wired in. Off costs nothing. */
  readonly #log: DebugLog | null;
  #inflight = 0;

  constructor(write: WriteFrame, log: DebugLog | null = null) {
    this.#write = write;
    this.#log = log;
  }

  /** Requests accepted but not yet answered. Shutdown drains these first. */
  get inflight(): number {
    return this.#inflight;
  }

  register(method: string, handler: Handler): void {
    if (this.#handlers.has(method)) throw new Error(`duplicate handler for ${method}`);
    this.#handlers.set(method, handler);
  }

  /**
   * A rejected line is answered against its own id whenever it named one; only
   * a line with no usable id becomes an `rpc.error` event. The plugin promises
   * exactly one callback per request, and an event settles nothing.
   */
  handleLine(line: string): void {
    let request: RequestFrame;
    try {
      request = parseRequest(line);
    } catch (cause) {
      const error = cause instanceof ProtocolError ? cause.toFrameError() : rpcError('internal', String(cause));
      const id = cause instanceof ProtocolError ? cause.requestId : undefined;
      if (id === undefined) this.#write({ event: 'rpc.error', params: { error } });
      else this.#write({ id, ok: false, error });
      return;
    }
    void this.#dispatch(request);
  }

  async #dispatch(request: RequestFrame): Promise<void> {
    const handler = this.#handlers.get(request.method);
    if (handler === undefined) {
      // Logged like any other request: a plugin/sidecar version mismatch is
      // what this log exists to diagnose, and a reply with no request above it
      // reads as a frame the timeline lost.
      this.#log?.request(request.method, request.id, request.params);
      this.#write({
        id: request.id,
        ok: false,
        error: rpcError('unknown_method', `unknown method ${request.method}`),
      });
      this.#log?.reply(request.method, request.id, 0, 'unknown_method');
      return;
    }
    this.#inflight += 1;
    this.#log?.request(request.method, request.id, request.params);
    const started = Date.now();
    try {
      const result = await handler(request.id, request.params);
      this.#write({ id: request.id, ok: true, result });
      this.#log?.reply(request.method, request.id, Date.now() - started);
    } catch (cause) {
      const error = toFrameError(cause);
      this.#write({ id: request.id, ok: false, error });
      this.#log?.reply(request.method, request.id, Date.now() - started, error.code);
    } finally {
      this.#inflight -= 1;
    }
  }
}

function toFrameError(cause: unknown) {
  if (cause instanceof ProtocolError) return cause.toFrameError();
  const message = cause instanceof Error ? cause.message : String(cause);
  const stack = cause instanceof Error ? cause.stack : undefined;
  return rpcError('internal', message, stack);
}
