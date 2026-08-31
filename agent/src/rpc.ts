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
  #inflight = 0;

  constructor(write: WriteFrame) {
    this.#write = write;
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
   * A line that cannot be attributed to a request has no id to answer, so it
   * is reported as an `rpc.error` event rather than dropped.
   */
  handleLine(line: string): void {
    let request: RequestFrame;
    try {
      request = parseRequest(line);
    } catch (cause) {
      const error = cause instanceof ProtocolError ? cause.toFrameError() : rpcError('internal', String(cause));
      this.#write({ event: 'rpc.error', params: { error } });
      return;
    }
    void this.#dispatch(request);
  }

  async #dispatch(request: RequestFrame): Promise<void> {
    const handler = this.#handlers.get(request.method);
    if (handler === undefined) {
      this.#write({
        id: request.id,
        ok: false,
        error: rpcError('unknown_method', `unknown method ${request.method}`),
      });
      return;
    }
    this.#inflight += 1;
    try {
      const result = await handler(request.id, request.params);
      this.#write({ id: request.id, ok: true, result });
    } catch (cause) {
      this.#write({ id: request.id, ok: false, error: toFrameError(cause) });
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
