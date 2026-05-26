export interface Options {
	/**
	 * Setting this to true will yield an array. In other words; instead of yielding once for every payload—we collect
	 * all complete payloads for a chunk and then yield.
	 *
	 * @default false
	 */
	multiple: boolean;
}

export type Part<Body, Fallback> =
	| { json: false; headers: Record<string, string>; body: Fallback }
	| { json: true; headers: Record<string, string>; body: Body };

// TODO: is there a way to compose the `meros/{node,browser}` here without having to duplicate the entire signature? And maintain jsdocs

// -- NODE

import type { IncomingMessage } from 'node:http';

export function meros<T = object>(
	response: IncomingMessage,
	options: { multiple: true },
): Promise<IncomingMessage | AsyncGenerator<ReadonlyArray<Part<T, Buffer>>>>;
export function meros<T = object>(
	response: IncomingMessage,
	options?: { multiple: false },
): Promise<IncomingMessage | AsyncGenerator<Part<T, Buffer>>>;
export function meros<T = object>(
	response: IncomingMessage,
	options?: Options,
): Promise<IncomingMessage | AsyncGenerator<Part<T, Buffer>>>;

// -- BROWSER

export function meros<T = object>(
	response: Response,
	options: { multiple: true },
): Promise<Response | AsyncGenerator<ReadonlyArray<Part<T, string>>>>;
export function meros<T = object>(
	response: Response,
	options?: { multiple: false },
): Promise<Response | AsyncGenerator<Part<T, string>>>;
export function meros<T = object>(
	response: Response,
	options?: Options,
): Promise<Response | AsyncGenerator<Part<T, string>>>;
