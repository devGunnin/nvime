import { isAbsolute } from 'node:path';
import { ProtocolError } from './protocol.js';

/** Validators for request params. Every failure is a `bad_request` the plugin renders. */

function reject(message: string): never {
  throw new ProtocolError('bad_request', message);
}

export function requireString(params: Record<string, unknown>, key: string): string {
  const value = params[key];
  if (typeof value !== 'string' || value === '') reject(`params.${key} must be a non-empty string`);
  return value;
}

export function optionalString(params: Record<string, unknown>, key: string): string | undefined {
  const value = params[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string' || value === '') reject(`params.${key} must be a non-empty string`);
  return value;
}

export function requireAbsolutePath(params: Record<string, unknown>, key: string): string {
  const value = requireString(params, key);
  if (!isAbsolute(value)) reject(`params.${key} must be an absolute path`);
  return value;
}

export function optionalPositiveInt(
  params: Record<string, unknown>,
  key: string,
  max: number,
): number | undefined {
  const value = params[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1 || value > max) {
    reject(`params.${key} must be an integer in 1..${max}`);
  }
  return value;
}

export function requireBoolean(params: Record<string, unknown>, key: string): boolean {
  const value = params[key];
  if (typeof value !== 'boolean') reject(`params.${key} must be a boolean`);
  return value;
}

export function optionalBoolean(params: Record<string, unknown>, key: string): boolean | undefined {
  const value = params[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'boolean') reject(`params.${key} must be a boolean`);
  return value;
}

export function requireArray(params: Record<string, unknown>, key: string): unknown[] {
  const value = params[key];
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) reject(`params.${key} must be an array`);
  return value;
}
