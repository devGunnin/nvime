/**
 * Wire protocol between the Neovim plugin and the sidecar: newline-delimited
 * JSON over stdio.
 *
 *   plugin -> agent   {"id":1,"method":"chat.send","params":{...}}
 *   agent  -> plugin  {"id":1,"ok":true,"result":{...}}          (response)
 *   agent  -> plugin  {"id":1,"ok":false,"error":{...}}          (response)
 *   agent  -> plugin  {"event":"chat.delta","params":{...}}      (server push)
 *
 * A response terminates its request; `chat.send` answers with the run's
 * completion payload (session id + usage), so there is exactly one completion
 * path per request rather than a separate done event.
 */

export type RequestId = number;

/** Every failure the plugin can render. Codes are stable; messages are not. */
export type ErrorCode =
  | 'bad_request'
  | 'unknown_method'
  | 'busy'
  | 'cancelled'
  | 'claude_not_found'
  | 'not_logged_in'
  | 'agent_error'
  | 'internal';

export interface RpcError {
  code: ErrorCode;
  message: string;
  detail?: string;
}

export interface RequestFrame {
  id: RequestId;
  method: string;
  params: Record<string, unknown>;
}

export interface ResponseFrame {
  id: RequestId;
  ok: boolean;
  result?: unknown;
  error?: RpcError;
}

export interface EventFrame {
  event: string;
  params: Record<string, unknown>;
}

export type OutgoingFrame = ResponseFrame | EventFrame;

/** A line longer than this means the peer is desynchronized, not verbose. */
export const MAX_LINE_BYTES = 16 * 1024 * 1024;

export class ProtocolError extends Error {
  readonly code: ErrorCode;
  readonly detail?: string | undefined;
  /** Set when a rejected line still named a usable id, so it can be answered. */
  readonly requestId?: RequestId | undefined;
  constructor(code: ErrorCode, message: string, detail?: string, requestId?: RequestId) {
    super(message);
    this.name = 'ProtocolError';
    this.code = code;
    this.detail = detail;
    this.requestId = requestId;
  }

  toFrameError(): RpcError {
    return rpcError(this.code, this.message, this.detail);
  }
}

export function rpcError(code: ErrorCode, message: string, detail?: string): RpcError {
  return detail === undefined ? { code, message } : { code, message, detail };
}

/**
 * Reassembles newline-delimited frames from arbitrarily chunked stdin. Holds
 * at most one partial line; a run-on line is a fatal desync, not a big message.
 */
export class LineSplitter {
  #buffer = '';

  push(chunk: string): string[] {
    this.#buffer += chunk;
    const lines: string[] = [];
    let start = 0;
    for (;;) {
      const nl = this.#buffer.indexOf('\n', start);
      if (nl === -1) break;
      const line = this.#buffer.slice(start, nl).trim();
      if (line !== '') lines.push(line);
      start = nl + 1;
    }
    this.#buffer = this.#buffer.slice(start);
    if (Buffer.byteLength(this.#buffer, 'utf8') > MAX_LINE_BYTES) {
      this.#buffer = '';
      throw new ProtocolError(
        'bad_request',
        `incoming line exceeded ${MAX_LINE_BYTES} bytes without a newline`,
      );
    }
    return lines;
  }

  /** Bytes held back waiting for a newline. Tests and shutdown checks use it. */
  get pending(): number {
    return Buffer.byteLength(this.#buffer, 'utf8');
  }
}

export function encodeFrame(frame: OutgoingFrame): string {
  const line = JSON.stringify(frame);
  if (line.includes('\n')) {
    throw new ProtocolError('internal', 'encoded frame contains a newline');
  }
  return line + '\n';
}

/**
 * Parses one incoming line. Throws ProtocolError; once `id` has validated the
 * error carries it, so the caller answers that request instead of pushing an
 * unattributable event and leaving the plugin's callback hanging forever.
 */
export function parseRequest(line: string): RequestFrame {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch (cause) {
    throw new ProtocolError('bad_request', `malformed JSON: ${(cause as Error).message}`);
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new ProtocolError('bad_request', 'frame must be a JSON object');
  }
  const frame = raw as Record<string, unknown>;
  if (typeof frame.id !== 'number' || !Number.isSafeInteger(frame.id)) {
    throw new ProtocolError('bad_request', 'frame.id must be a safe integer');
  }
  const id = frame.id;
  if (typeof frame.method !== 'string' || frame.method === '') {
    throw new ProtocolError('bad_request', 'frame.method must be a non-empty string', undefined, id);
  }
  const params = frame.params;
  if (params !== undefined && (typeof params !== 'object' || params === null || Array.isArray(params))) {
    throw new ProtocolError('bad_request', 'frame.params must be an object when present', undefined, id);
  }
  return {
    id,
    method: frame.method,
    params: (params as Record<string, unknown> | undefined) ?? {},
  };
}
