// A stand-in for the `fetchMock` export that `cloudflare:test` used to provide.
//
// @cloudflare/vitest-pool-workers dropped `fetchMock` (undici's MockAgent) in
// 0.13.0: the export is gone from both the runtime and the type declarations,
// and Cloudflare's migration guide points at @msw/cloudflare instead. The seven
// proxy/rate-limit/feedback suites that assert on outbound requests are built on
// its `get(origin).intercept({method, path, headers, body}).reply(status, body)`
// shape, and the assertions they make -- which URL the Worker actually
// requested, which headers and body it sent, that a cache hit costs no upstream
// call, that an oversized body is rejected without buffering -- are about the
// Worker, not about the mock library. Rewriting them onto MSW would change every
// one of those call sites for no gain.
//
// So this module implements the subset of that API the suite uses, over a
// `globalThis.fetch` patch. The Worker and the tests share one isolate (the same
// property that makes `SELF.fetch` observe global mocks), so a patched global
// fetch intercepts the Worker's own outbound requests.
//
// `fetchMock.activate()` installs the patch; every suite then calls
// `disableNetConnect()`, which makes an unmatched request reject instead of
// reaching the network -- that strictness is what turns "the Worker called an
// upstream nobody mocked" into a failure rather than a real request. The reject
// is also load-bearing for routes that deliberately exercise a failing upstream:
// the route catches it and answers 500.
//
// `assertNoPendingInterceptors()` is the other half: a reply registered but never
// consumed fails the test, which is how a suite proves an upstream call did NOT
// happen (e.g. the second request for a cached TMDB movie), and how the feedback
// suite proves it made exactly as many Resend calls as it registered.
//
// Deliberately not implemented, because no suite uses them: `.times()`,
// `.persist()`, `.delay()`, `.replyWithError()`, `enableNetConnect()`. A call to
// one of those is a compile error rather than a silent no-op.
//
// Body handling mirrors undici's mock, which the suite's own comments already
// document: an object body is JSON with `content-type: application/json`, a
// Buffer body is the raw bytes with no headers at all (a bare `Uint8Array` would
// serialize as JSON, its numeric indices becoming object keys), and a string
// body is text. Header matchers receive lower-cased names, as undici's did.

type PathMatcher = string | ((path: string) => boolean);

interface InterceptOptions {
  method?: string;
  path?: PathMatcher;
  headers?: (headers: Record<string, string>) => boolean;
  body?: string | ((body: string) => boolean);
}

interface ReplyOptions {
  headers?: Record<string, string>;
}

interface Interceptable {
  intercept(options: InterceptOptions): {
    reply(status: number, data?: unknown, options?: ReplyOptions): void;
  };
}

interface Interceptor {
  origin: string;
  method: string;
  path: PathMatcher | undefined;
  headerMatcher: ((headers: Record<string, string>) => boolean) | undefined;
  bodyMatcher: string | ((body: string) => boolean) | undefined;
  status: number;
  responseBody: BodyInit | null;
  responseHeaders: Record<string, string>;
  consumed: boolean;
}

const interceptors: Interceptor[] = [];
const realFetch = globalThis.fetch;
let installed = false;
let netConnectDisabled = false;

function describe(interceptor: Interceptor): string {
  const path =
    typeof interceptor.path === "function" ? "<predicate>" : (interceptor.path ?? "<any>");
  return `${interceptor.method} ${interceptor.origin}${path}`;
}

function matchesPath(matcher: PathMatcher | undefined, path: string): boolean {
  if (matcher === undefined) return true;
  if (typeof matcher === "function") return matcher(path);
  return matcher === path;
}

function matchesBody(matcher: string | ((body: string) => boolean) | undefined, body: string): boolean {
  if (matcher === undefined) return true;
  if (typeof matcher === "function") return matcher(body);
  return matcher === body;
}

function encodeBody(
  data: unknown,
  options: ReplyOptions | undefined,
): { responseBody: BodyInit | null; responseHeaders: Record<string, string> } {
  if (Buffer.isBuffer(data)) {
    return { responseBody: data as Uint8Array, responseHeaders: { ...options?.headers } };
  }
  if (data !== null && typeof data === "object") {
    return {
      responseBody: JSON.stringify(data),
      // The caller's explicit headers win, as they do in undici's mock.
      responseHeaders: { "content-type": "application/json", ...options?.headers },
    };
  }
  return {
    responseBody: data === undefined ? null : String(data),
    responseHeaders: { ...options?.headers },
  };
}

function requestHeaders(
  input: RequestInfo | URL,
  init: RequestInit | undefined,
): Record<string, string> {
  const headers = new Headers(
    init?.headers ?? (input instanceof Request ? input.headers : undefined),
  );
  const record: Record<string, string> = {};
  headers.forEach((value, name) => {
    record[name] = value;
  });
  return record;
}

async function requestBody(
  input: RequestInfo | URL,
  init: RequestInit | undefined,
): Promise<string> {
  if (typeof init?.body === "string") return init.body;
  if (input instanceof Request) return input.clone().text();
  if (init?.body != null) return new Response(init.body).text();
  return "";
}

async function mockedFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const url = input instanceof Request ? new URL(input.url) : new URL(String(input));
  const method = (init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase();
  const path = `${url.pathname}${url.search}`;

  // Headers and body are read only if a candidate actually asks about them:
  // most replies do not, and reading a body is asynchronous.
  let seenHeaders: Record<string, string> | undefined;
  let seenBody: string | undefined;

  let matched: Interceptor | undefined;
  for (const candidate of interceptors) {
    if (candidate.consumed) continue;
    if (candidate.origin !== url.origin || candidate.method !== method) continue;
    if (!matchesPath(candidate.path, path)) continue;
    if (candidate.headerMatcher !== undefined) {
      seenHeaders ??= requestHeaders(input, init);
      if (!candidate.headerMatcher(seenHeaders)) continue;
    }
    if (candidate.bodyMatcher !== undefined) {
      seenBody ??= await requestBody(input, init);
      if (!matchesBody(candidate.bodyMatcher, seenBody)) continue;
    }
    matched = candidate;
    break;
  }

  if (matched !== undefined) {
    matched.consumed = true;
    return new Response(matched.responseBody, {
      status: matched.status,
      headers: matched.responseHeaders,
    });
  }

  if (netConnectDisabled) {
    const registered = interceptors
      .map((candidate) => `  ${describe(candidate)}`)
      .join("\n");
    throw new Error(
      `fetch-mock: no interceptor for ${method} ${url.origin}${path}` +
        (registered === "" ? "" : `\nregistered:\n${registered}`),
    );
  }

  return realFetch(input, init);
}

export const fetchMock = {
  activate(): void {
    if (installed) return;
    globalThis.fetch = mockedFetch as typeof fetch;
    installed = true;
  },

  deactivate(): void {
    if (!installed) return;
    globalThis.fetch = realFetch;
    installed = false;
  },

  disableNetConnect(): void {
    netConnectDisabled = true;
  },

  get(origin: string): Interceptable {
    return {
      intercept(interceptOptions: InterceptOptions) {
        return {
          reply(status: number, data?: unknown, replyOptions?: ReplyOptions): void {
            interceptors.push({
              origin,
              method: (interceptOptions.method ?? "GET").toUpperCase(),
              path: interceptOptions.path,
              headerMatcher: interceptOptions.headers,
              bodyMatcher: interceptOptions.body,
              status,
              ...encodeBody(data, replyOptions),
              consumed: false,
            });
          },
        };
      },
    };
  },

  assertNoPendingInterceptors(): void {
    const pending = interceptors.filter((candidate) => !candidate.consumed);
    if (pending.length === 0) return;
    throw new Error(
      `fetch-mock: ${pending.length} interceptor(s) never matched a request:\n` +
        pending.map((candidate) => `  ${describe(candidate)}`).join("\n"),
    );
  },
};
