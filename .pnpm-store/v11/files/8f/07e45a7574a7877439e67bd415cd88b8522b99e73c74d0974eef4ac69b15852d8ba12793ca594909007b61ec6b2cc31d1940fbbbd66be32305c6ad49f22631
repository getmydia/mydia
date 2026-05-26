'use strict';

var signal = require('@graphql-hive/signal');
var executorCommon = require('@graphql-tools/executor-common');
var utils = require('@graphql-tools/utils');
var disposablestack = require('@whatwg-node/disposablestack');
var fetch = require('@whatwg-node/fetch');
var promiseHelpers = require('@whatwg-node/promise-helpers');
var repeater = require('@repeaterjs/repeater');
var graphql = require('graphql');
var browser = require('meros/browser');
var node = require('meros/node');

function isPlainObject(value) {
	if (typeof value !== 'object' || value === null) {
		return false;
	}

	const prototype = Object.getPrototypeOf(value);
	return (prototype === null || prototype === Object.prototype || Object.getPrototypeOf(prototype) === null) && !(Symbol.toStringTag in value) && !(Symbol.iterator in value);
}

// @ts-check


/** @typedef {import("./isExtractableFile.mjs").default} isExtractableFile */

/**
 * Recursively extracts files and their {@link ObjectPath object paths} within a
 * value, replacing them with `null` in a deep clone without mutating the
 * original value.
 * [`FileList`](https://developer.mozilla.org/en-US/docs/Web/API/Filelist)
 * instances are treated as
 * [`File`](https://developer.mozilla.org/en-US/docs/Web/API/File) instance
 * arrays.
 * @template Extractable Extractable file type.
 * @param {unknown} value Value to extract files from. Typically an object tree.
 * @param {(value: unknown) => value is Extractable} isExtractable Matches
 *   extractable files. Typically {@linkcode isExtractableFile}.
 * @param {ObjectPath} [path] Prefix for object paths for extracted files.
 *   Defaults to `""`.
 * @returns {Extraction<Extractable>} Extraction result.
 * @example
 * Extracting files from an object.
 *
 * For the following:
 *
 * ```js
 * import extractFiles from "extract-files/extractFiles.mjs";
 * import isExtractableFile from "extract-files/isExtractableFile.mjs";
 *
 * const file1 = new File(["1"], "1.txt", { type: "text/plain" });
 * const file2 = new File(["2"], "2.txt", { type: "text/plain" });
 * const value = {
 *   a: file1,
 *   b: [file1, file2],
 * };
 *
 * const { clone, files } = extractFiles(value, isExtractableFile, "prefix");
 * ```
 *
 * `value` remains the same.
 *
 * `clone` is:
 *
 * ```json
 * {
 *   "a": null,
 *   "b": [null, null]
 * }
 * ```
 *
 * `files` is a
 * [`Map`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Map)
 * instance containing:
 *
 * | Key     | Value                        |
 * | :------ | :--------------------------- |
 * | `file1` | `["prefix.a", "prefix.b.0"]` |
 * | `file2` | `["prefix.b.1"]`             |
 */
function extractFiles(value, isExtractable, path = "") {
  if (!arguments.length) throw new TypeError("Argument 1 `value` is required.");

  if (typeof isExtractable !== "function")
    throw new TypeError("Argument 2 `isExtractable` must be a function.");

  if (typeof path !== "string")
    throw new TypeError("Argument 3 `path` must be a string.");

  /**
   * Deeply clonable value.
   * @typedef {Array<unknown> | FileList | {
   *   [key: PropertyKey]: unknown
   * }} Cloneable
   */

  /**
   * Clone of a {@link Cloneable deeply cloneable value}.
   * @typedef {Exclude<Cloneable, FileList>} Clone
   */

  /**
   * Map of values recursed within the input value and their clones, for reusing
   * clones of values that are referenced multiple times within the input value.
   * @type {Map<Cloneable, Clone>}
   */
  const clones = new Map();

  /**
   * Extracted files and their object paths within the input value.
   * @type {Extraction<Extractable>["files"]}
   */
  const files = new Map();

  /**
   * Recursively clones the value, extracting files.
   * @param {unknown} value Value to extract files from.
   * @param {ObjectPath} path Prefix for object paths for extracted files.
   * @param {Set<Cloneable>} recursed Recursed values for avoiding infinite
   *   recursion of circular references within the input value.
   * @returns {unknown} Clone of the value with files replaced with `null`.
   */
  function recurse(value, path, recursed) {
    if (isExtractable(value)) {
      const filePaths = files.get(value);

      filePaths ? filePaths.push(path) : files.set(value, [path]);

      return null;
    }

    const valueIsList =
      Array.isArray(value) ||
      (typeof FileList !== "undefined" && value instanceof FileList);
    const valueIsPlainObject = isPlainObject(value);

    if (valueIsList || valueIsPlainObject) {
      let clone = clones.get(value);

      const uncloned = !clone;

      if (uncloned) {
        clone = valueIsList
          ? []
          : // Replicate if the plain object is an `Object` instance.
          value instanceof /** @type {any} */ (Object)
          ? {}
          : Object.create(null);

        clones.set(value, /** @type {Clone} */ (clone));
      }

      if (!recursed.has(value)) {
        const pathPrefix = path ? `${path}.` : "";
        const recursedDeeper = new Set(recursed).add(value);

        if (valueIsList) {
          let index = 0;

          for (const item of value) {
            const itemClone = recurse(
              item,
              pathPrefix + index++,
              recursedDeeper
            );

            if (uncloned) /** @type {Array<unknown>} */ (clone).push(itemClone);
          }
        } else
          for (const key in value) {
            const propertyClone = recurse(
              value[key],
              pathPrefix + key,
              recursedDeeper
            );

            if (uncloned)
              /** @type {{ [key: PropertyKey]: unknown }} */ (clone)[key] =
                propertyClone;
          }
      }

      return clone;
    }

    return value;
  }

  return {
    clone: recurse(value, path, new Set()),
    files,
  };
}

/**
 * An extraction result.
 * @template [Extractable=unknown] Extractable file type.
 * @typedef {object} Extraction
 * @prop {unknown} clone Clone of the original value with extracted files
 *   recursively replaced with `null`.
 * @prop {Map<Extractable, Array<ObjectPath>>} files Extracted files and their
 *   object paths within the original value.
 */

/**
 * String notation for the path to a node in an object tree.
 * @typedef {string} ObjectPath
 * @see [`object-path` on npm](https://npm.im/object-path).
 * @example
 * An object path for object property `a`, array index `0`, object property `b`:
 *
 * ```
 * a.0.b
 * ```
 */

// @ts-check

/**
 * Checks if a value is an {@link ExtractableFile extractable file}.
 * @param {unknown} value Value to check.
 * @returns {value is ExtractableFile} Is the value an
 *   {@link ExtractableFile extractable file}.
 */
function isExtractableFile(value) {
  return (
    (typeof File !== "undefined" && value instanceof File) ||
    (typeof Blob !== "undefined" && value instanceof Blob)
  );
}

/**
 * An extractable file.
 * @typedef {File | Blob} ExtractableFile
 */

function isGraphQLUpload(upload) {
  return typeof upload.createReadStream === "function";
}

function collectAsyncIterableValues(asyncIterable) {
  const values = [];
  const iterator = asyncIterable[Symbol.asyncIterator]();
  function iterate() {
    return promiseHelpers.handleMaybePromise(
      () => iterator.next(),
      ({ value, done }) => {
        if (value != null) {
          values.push(value);
        }
        if (done) {
          return values;
        }
        return iterate();
      }
    );
  }
  return iterate();
}
function createFormDataFromVariables(body, {
  File: FileCtor = fetch.File,
  FormData: FormDataCtor = fetch.FormData
}) {
  if (!body.variables) {
    return JSON.stringify(body);
  }
  const vars = Object.assign({}, body.variables);
  const { clone, files } = extractFiles(
    vars,
    ((v) => isExtractableFile(v) || v?.promise || utils.isAsyncIterable(v) || v?.then || typeof v?.arrayBuffer === "function"),
    "variables"
  );
  if (files.size === 0) {
    return JSON.stringify(body);
  }
  const map = {};
  const uploads = [];
  let currIndex = 0;
  for (const [file, curr] of files) {
    map[currIndex] = curr;
    uploads[currIndex] = file;
    currIndex++;
  }
  const form = new FormDataCtor();
  form.append(
    "operations",
    JSON.stringify({
      ...body,
      variables: clone
    })
  );
  form.append("map", JSON.stringify(map));
  function handleUpload(upload, i) {
    const indexStr = i.toString();
    if (upload != null) {
      return promiseHelpers.handleMaybePromise(
        () => upload?.promise || upload,
        (upload2) => {
          const filename = upload2.filename || upload2.name || upload2.path || `blob-${indexStr}`;
          if (isBlob(upload2)) {
            form.append(indexStr, upload2, filename);
          } else if (utils.isAsyncIterable(upload2)) {
            return promiseHelpers.handleMaybePromise(
              () => collectAsyncIterableValues(upload2),
              (chunks) => {
                const blobPart = new Uint8Array(chunks);
                form.append(
                  indexStr,
                  new FileCtor([blobPart], filename),
                  filename
                );
              }
            );
          } else if (isGraphQLUpload(upload2)) {
            return promiseHelpers.handleMaybePromise(
              () => collectAsyncIterableValues(upload2.createReadStream()),
              (chunks) => {
                const blobPart = new Uint8Array(chunks);
                form.append(
                  indexStr,
                  new FileCtor([blobPart], filename, { type: upload2.mimetype }),
                  filename
                );
              }
            );
          } else {
            form.append(indexStr, new FileCtor([upload2], filename), filename);
          }
        }
      );
    }
  }
  const jobs = [];
  for (const i in uploads) {
    const upload = uploads[i];
    const job = handleUpload(upload, Number(i));
    if (promiseHelpers.isPromise(job)) {
      jobs.push(job);
    }
  }
  if (jobs.length > 0) {
    return Promise.all(jobs).then(() => form);
  }
  return form;
}
function isBlob(obj) {
  return typeof obj.arrayBuffer === "function";
}

function createGraphQLErrorForAbort(reason, extensions) {
  if (reason instanceof graphql.GraphQLError) {
    return reason;
  }
  if (reason?.name === "TimeoutError") {
    return utils.createGraphQLError(reason.message, {
      extensions: {
        http: {
          status: 504,
          ...extensions?.["http"] || {}
        },
        code: "TIMEOUT_ERROR",
        ...extensions || {}
      },
      originalError: reason
    });
  }
  return utils.createGraphQLError(reason.message, {
    extensions,
    originalError: reason
  });
}
function createResultForAbort(reason, extensions) {
  return {
    errors: [createGraphQLErrorForAbort(reason, extensions)]
  };
}
function hashSHA256(str) {
  const textEncoder = new fetch.TextEncoder();
  const utf8 = textEncoder.encode(str);
  return promiseHelpers.handleMaybePromise(
    () => fetch.crypto.subtle.digest("SHA-256", utf8),
    (hashBuffer) => {
      let hashHex = "";
      for (const bytes of new Uint8Array(hashBuffer)) {
        hashHex += bytes.toString(16).padStart(2, "0");
      }
      return hashHex;
    }
  );
}

const DELIM = "\n\n";
function isReadableStream(value) {
  return value && typeof value.getReader === "function";
}
function handleEventStreamResponse(response, subscriptionCtrl, signal) {
  const body = response.body;
  if (!isReadableStream(body)) {
    throw new Error(
      "Response body is expected to be a readable stream but got; " + utils.inspect(body)
    );
  }
  return new repeater.Repeater((push, stop) => {
    const decoder = new fetch.TextDecoder();
    const reader = body.getReader();
    let closed = false;
    reader.closed.then(() => closed = true).catch((reason) => closed = reason);
    stop.then(() => {
      subscriptionCtrl?.abort();
      if (body.locked) {
        reader.releaseLock();
      }
    }).catch((err) => {
      reader.cancel(err);
    });
    let currChunk = "";
    async function pump() {
      if (signal?.aborted) {
        await push(createResultForAbort(signal.reason));
        return stop();
      }
      if (!body?.locked) {
        return stop();
      }
      let done, chunk;
      try {
        const result = await reader.read();
        done = result.done;
        chunk = result.value;
      } catch (err) {
        if (signal?.aborted) {
          await push(createResultForAbort(signal.reason));
          return stop();
        }
        const errErr = err instanceof Error ? err : new Error(String(err));
        await push({
          errors: [
            utils.createGraphQLError(errErr.message, { originalError: errErr })
          ]
        });
        return stop();
      }
      if (done) {
        return stop();
      }
      currChunk += typeof chunk === "string" ? chunk : decoder.decode(chunk);
      for (; ; ) {
        const delimIndex = currChunk.indexOf(DELIM);
        if (delimIndex === -1) {
          break;
        }
        const msg = currChunk.slice(0, delimIndex);
        currChunk = currChunk.slice(delimIndex + DELIM.length);
        const dataStr = msg.split("\n").filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
        if (dataStr) {
          const data = JSON.parse(dataStr);
          await push(data.payload || data);
        }
        const event = msg.split("event:")[1]?.trim().split("\n")[0]?.trim();
        if (event === "complete") {
          return stop();
        }
      }
      if (closed) {
        return stop();
      }
      return pump();
    }
    return pump();
  });
}

function isIncomingMessage(body) {
  return body != null && typeof body === "object" && "pipe" in body;
}
async function handleMultipartMixedResponse(response) {
  const body = response.body;
  const contentType = response.headers.get("content-type") || "";
  let asyncIterator;
  if (isIncomingMessage(body)) {
    body.headers = {
      "content-type": contentType
    };
    const result = await node.meros(body);
    if ("next" in result) {
      asyncIterator = result;
    }
  } else {
    const result = await browser.meros(response);
    if ("next" in result) {
      asyncIterator = result;
    }
  }
  const executionResult = {};
  if (asyncIterator == null) {
    return executionResult;
  }
  const resultStream = utils.mapAsyncIterator(asyncIterator, (part) => {
    if (part.json) {
      const incrementalResult = part.body;
      utils.mergeIncrementalResult({
        incrementalResult,
        executionResult
      });
    }
    return executionResult;
  });
  return resultStream;
}

const isLiveQueryOperationDefinitionNode = utils.memoize1(
  function isLiveQueryOperationDefinitionNode2(node) {
    return node.operation === "query" && node.directives?.some((directive) => directive.name.value === "live");
  }
);

function prepareGETUrl({
  baseUrl = "",
  body
}) {
  const dummyHostname = "https://dummyhostname.com";
  const validUrl = baseUrl.startsWith("http") ? baseUrl : baseUrl?.startsWith("/") ? `${dummyHostname}${baseUrl}` : `${dummyHostname}/${baseUrl}`;
  const urlObj = new URL(validUrl);
  if (body.query) {
    urlObj.searchParams.set("query", body.query);
  }
  if (body.variables && Object.keys(body.variables).length > 0) {
    urlObj.searchParams.set("variables", JSON.stringify(body.variables));
  }
  if (body.operationName) {
    urlObj.searchParams.set("operationName", body.operationName);
  }
  if (body.extensions) {
    urlObj.searchParams.set("extensions", JSON.stringify(body.extensions));
  }
  const finalUrl = urlObj.toString().replace(dummyHostname, "");
  return finalUrl;
}

const inflightRequests = /* @__PURE__ */ new Map();
function buildHTTPExecutor(options) {
  const printFn = options?.print ?? executorCommon.defaultPrintFn;
  let disposeCtrl;
  const baseExecutor = (request, excludeQuery) => {
    if (!request.context?.request?.cf) {
      disposeCtrl ||= new AbortController();
    }
    if (disposeCtrl?.signal.aborted) {
      return createResultForAbort(disposeCtrl.signal.reason);
    }
    const fetchFn = request.extensions?.fetch ?? options?.fetch ?? fetch.fetch;
    let method = request.extensions?.method || options?.method;
    const operationAst = utils.getOperationASTFromRequest(request);
    const operationType = operationAst.operation;
    if (operationType === "query" && (options?.useGETForQueries || request.extensions?.useGETForQueries || (options?.useGETForHashedQueries || request.extensions?.useGETForHashedQueries) && excludeQuery)) {
      method = "GET";
    }
    let accept = "application/graphql-response+json, application/json, multipart/mixed";
    let subscriptionCtrl;
    if (operationType === "subscription" || isLiveQueryOperationDefinitionNode(operationAst)) {
      method ||= "GET";
      accept = "text/event-stream";
      subscriptionCtrl = new AbortController();
    } else {
      method ||= "POST";
    }
    let endpoint;
    if (request.extensions?.endpoint) {
      if (typeof request.extensions.endpoint === "string") {
        endpoint = request.extensions.endpoint;
      }
      if (typeof request.extensions.endpoint === "function") {
        endpoint = request.extensions.endpoint(request);
      }
    }
    if (!endpoint) {
      if (typeof options?.endpoint === "string") {
        endpoint = options.endpoint;
      }
      if (typeof options?.endpoint === "function") {
        endpoint = options.endpoint(request);
      }
    }
    if (!endpoint) {
      endpoint = "/graphql";
    }
    let isCustomHeader = false;
    const headers = { accept };
    if (options?.headers) {
      isCustomHeader = true;
      Object.assign(
        headers,
        typeof options?.headers === "function" ? options.headers(request) : options?.headers
      );
    }
    if (request.extensions?.headers) {
      isCustomHeader = true;
      const { headers: headersFromExtensions, ...restExtensions } = request.extensions;
      Object.assign(headers, headersFromExtensions);
      request.extensions = restExtensions;
    }
    const signals = [];
    if (disposeCtrl?.signal) {
      signals.push(disposeCtrl.signal);
    }
    const signalFromRequest = request.signal || request.info?.signal;
    if (signalFromRequest) {
      if (signalFromRequest.aborted) {
        return createResultForAbort(signalFromRequest.reason);
      }
      signals.push(signalFromRequest);
    }
    if (options?.timeout) {
      const timeout = typeof options.timeout === "number" ? options.timeout : options.timeout(request);
      if (timeout) {
        signals.push(AbortSignal.timeout(timeout));
      }
    }
    if (subscriptionCtrl) {
      signals.push(subscriptionCtrl.signal);
    }
    const signal$1 = signals.length ? signal.abortSignalAny(signals) : void 0;
    const upstreamErrorExtensions = {
      request: {
        method
      }
    };
    const query = printFn(request.document);
    let serializeFn = function serialize() {
      return executorCommon.serializeExecutionRequest({
        executionRequest: request,
        excludeQuery,
        printFn
      });
    };
    if (options?.apq) {
      serializeFn = function serializeWithAPQ() {
        return promiseHelpers.handleMaybePromise(
          () => hashSHA256(query),
          (sha256Hash) => {
            const extensions = request.extensions || {};
            extensions["persistedQuery"] = {
              version: 1,
              sha256Hash
            };
            return executorCommon.serializeExecutionRequest({
              executionRequest: {
                ...request,
                extensions
              },
              excludeQuery,
              printFn
            });
          }
        );
      };
    }
    function handleError(e) {
      upstreamErrorExtensions.code = "SUBREQUEST_HTTP_ERROR";
      if (e.name === "AggregateError") {
        return {
          errors: e.errors.map(
            (e2) => coerceFetchError(e2, {
              signal: signal$1,
              endpoint,
              upstreamErrorExtensions
            })
          )
        };
      }
      return {
        errors: [
          coerceFetchError(e, {
            signal: signal$1,
            endpoint,
            upstreamErrorExtensions
          })
        ]
      };
    }
    function handleInflightRequest(inflightRequestOptions, context, info) {
      if (options?.deduplicateInflightRequests === false || operationType !== "query") {
        return runInflightRequest();
      }
      function runInflightRequest() {
        const result$ = promiseHelpers.handleMaybePromise(
          () => fetchFn(
            inflightRequestOptions.url,
            {
              method: inflightRequestOptions.method,
              headers: inflightRequestOptions.headers,
              body: inflightRequestOptions.body,
              credentials: inflightRequestOptions.credentials,
              signal: inflightRequestOptions.signal
            },
            context,
            info
          ),
          (fetchResult) => promiseHelpers.handleMaybePromise(
            () => {
              upstreamErrorExtensions.response ||= {};
              upstreamErrorExtensions.response.status = fetchResult.status;
              upstreamErrorExtensions.response.statusText = fetchResult.statusText;
              if (options?.exposeHTTPDetailsInExtensions) {
                upstreamErrorExtensions.response.headers = Object.fromEntries(
                  fetchResult.headers.entries()
                );
              } else {
                Object.defineProperty(
                  upstreamErrorExtensions.response,
                  "headers",
                  {
                    get() {
                      return Object.fromEntries(
                        fetchResult.headers.entries()
                      );
                    }
                  }
                );
              }
              if (options?.retry != null && !fetchResult.status.toString().startsWith("2")) {
                throw new Error(
                  fetchResult.statusText || `Upstream HTTP Error: ${fetchResult.status}`
                );
              }
              const contentType = fetchResult.headers.get("content-type");
              if (contentType?.includes("text/event-stream")) {
                return handleEventStreamResponse(
                  fetchResult,
                  subscriptionCtrl,
                  signal$1
                );
              } else if (contentType?.includes("multipart/mixed")) {
                return handleMultipartMixedResponse(fetchResult);
              }
              return fetchResult.text();
            },
            (result) => {
              if (typeof result === "string") {
                upstreamErrorExtensions.response ||= {};
                upstreamErrorExtensions.response.body = result;
                if (result) {
                  try {
                    const parsedResult = JSON.parse(result);
                    upstreamErrorExtensions.response.body = parsedResult;
                    if (parsedResult.data == null && (parsedResult.errors == null || parsedResult.errors.length === 0)) {
                      const message = `Unexpected empty "data" and "errors" fields in result: ${result}`;
                      upstreamErrorExtensions.code = "RESPONSE_VALIDATION_FAILED";
                      return {
                        errors: [
                          utils.createGraphQLError(message, {
                            originalError: new Error(message),
                            extensions: upstreamErrorExtensions
                          })
                        ]
                      };
                    }
                    if (Array.isArray(parsedResult.errors)) {
                      return {
                        ...parsedResult,
                        errors: parsedResult.errors.map(
                          ({
                            message,
                            ...options2
                          }) => utils.createGraphQLError(message, options2)
                        )
                      };
                    }
                    return parsedResult;
                  } catch (e) {
                    upstreamErrorExtensions.code = "RESPONSE_VALIDATION_FAILED";
                    return {
                      errors: [
                        utils.createGraphQLError(
                          `Unexpected response: ${JSON.stringify(result)}`,
                          {
                            extensions: upstreamErrorExtensions,
                            originalError: e
                          }
                        )
                      ]
                    };
                  }
                } else {
                  const message = "No response returned";
                  upstreamErrorExtensions.code = "RESPONSE_VALIDATION_FAILED";
                  return {
                    errors: [
                      utils.createGraphQLError(message, {
                        extensions: upstreamErrorExtensions,
                        originalError: new Error(message)
                      })
                    ]
                  };
                }
              } else {
                return result;
              }
            },
            handleError
          ),
          handleError
        );
        if (options?.exposeHTTPDetailsInExtensions) {
          return promiseHelpers.handleMaybePromise(
            () => result$,
            (result) => {
              if (upstreamErrorExtensions.response?.body) {
                upstreamErrorExtensions.response.body = structuredClone(
                  upstreamErrorExtensions.response.body
                );
              }
              result.extensions ||= {};
              result.extensions = Object.assign(
                result.extensions,
                upstreamErrorExtensions
              );
              return result;
            }
          );
        }
        return result$;
      }
      if (typeof inflightRequestOptions.body === "object") {
        return runInflightRequest();
      }
      let inflightRequestId = `${inflightRequestOptions.url}|${inflightRequestOptions.method}`;
      if (inflightRequestOptions.body) {
        inflightRequestId += `|${inflightRequestOptions.body}`;
      }
      if (isCustomHeader) {
        inflightRequestId += `|${JSON.stringify(inflightRequestOptions.headers)}`;
      }
      let inflightRequest = inflightRequests.get(inflightRequestId);
      if (!inflightRequest) {
        inflightRequest = runInflightRequest();
        if (promiseHelpers.isPromise(inflightRequest)) {
          inflightRequests.set(inflightRequestId, inflightRequest);
          inflightRequest.finally(() => {
            inflightRequests.delete(inflightRequestId);
          });
        }
      }
      return promiseHelpers.handleMaybePromise(
        () => inflightRequest,
        (result) => {
          if (result == null || !result.data) {
            return result;
          }
          const clonedResult = {
            ...result
          };
          if (result.data) {
            clonedResult.data = structuredClone(result.data);
          }
          return clonedResult;
        }
      );
    }
    return promiseHelpers.handleMaybePromise(
      () => serializeFn(),
      (body) => {
        switch (method) {
          case "GET": {
            if ((options?.useContentTypeForGETRequests || request.extensions?.useContentTypeForGETRequests) && !headers["content-type"]) {
              headers["content-type"] = "application/json";
            }
            const finalUrl = prepareGETUrl({
              baseUrl: endpoint,
              body
            });
            const inflightRequestOptions = {
              url: finalUrl,
              method: "GET",
              headers,
              signal: signal$1,
              credentials: options?.credentials
            };
            upstreamErrorExtensions.request.url = finalUrl;
            return handleInflightRequest(
              inflightRequestOptions,
              request.context,
              request.info
            );
          }
          case "POST": {
            upstreamErrorExtensions.request.body = body;
            return promiseHelpers.handleMaybePromise(
              () => createFormDataFromVariables(body, {
                File: options?.File,
                FormData: options?.FormData
              }),
              (body2) => {
                if (typeof body2 === "string" && !headers["content-type"]) {
                  upstreamErrorExtensions.request.body = body2;
                  headers["content-type"] = "application/json";
                }
                const inflightRequestOptions = {
                  url: endpoint,
                  method: "POST",
                  body: body2,
                  headers,
                  credentials: options?.credentials,
                  signal: signal$1
                };
                return handleInflightRequest(
                  inflightRequestOptions,
                  request.context,
                  request.info
                );
              },
              handleError
            );
          }
        }
      },
      handleError
    );
  };
  let executor = baseExecutor;
  if (options?.apq != null) {
    executor = function apqExecutor(request) {
      return promiseHelpers.handleMaybePromise(
        () => baseExecutor(request, true),
        (res) => {
          if (res.errors?.some(
            (error) => error.extensions["code"] === "PERSISTED_QUERY_NOT_FOUND" || error.message === "PersistedQueryNotFound"
          )) {
            return baseExecutor(request, false);
          }
          return res;
        }
      );
    };
  }
  if (options?.retry != null) {
    const prevExecutor = executor;
    executor = function retryExecutor(request) {
      let result;
      let attempt = 0;
      function retryAttempt() {
        if (disposeCtrl?.signal.aborted) {
          return createResultForAbort(disposeCtrl.signal.reason);
        }
        attempt++;
        if (attempt > options.retry) {
          if (result != null) {
            return result;
          }
          return {
            errors: [utils.createGraphQLError("No response returned from fetch")]
          };
        }
        return promiseHelpers.handleMaybePromise(
          () => prevExecutor(request),
          (res) => {
            result = res;
            if (result?.errors?.length) {
              return retryAttempt();
            }
            return result;
          }
        );
      }
      return retryAttempt();
    };
  }
  Object.defineProperties(executor, {
    [disposablestack.DisposableSymbols.dispose]: {
      get() {
        return function dispose() {
          disposeCtrl?.abort(options?.getDisposeReason?.());
          disposeCtrl = void 0;
        };
      }
    },
    [disposablestack.DisposableSymbols.asyncDispose]: {
      get() {
        return function asyncDispose() {
          disposeCtrl?.abort(options?.getDisposeReason?.());
          disposeCtrl = void 0;
        };
      }
    }
  });
  return executor;
}
function coerceFetchError(e, {
  signal,
  endpoint,
  upstreamErrorExtensions
}) {
  if (typeof e === "string") {
    return utils.createGraphQLError(e, {
      extensions: upstreamErrorExtensions
    });
  } else if (e.name === "GraphQLError") {
    return e;
  } else if (e.name === "TypeError" && e.message === "fetch failed") {
    return utils.createGraphQLError(`fetch failed to ${endpoint}`, {
      extensions: upstreamErrorExtensions,
      originalError: e
    });
  } else if (e.name === "AbortError") {
    return createGraphQLErrorForAbort(
      signal?.reason || e,
      upstreamErrorExtensions
    );
  } else if (e.message) {
    return utils.createGraphQLError(e.message, {
      extensions: upstreamErrorExtensions,
      originalError: e
    });
  } else {
    return utils.createGraphQLError("Unknown error", {
      extensions: upstreamErrorExtensions,
      originalError: e
    });
  }
}

exports.buildHTTPExecutor = buildHTTPExecutor;
exports.isLiveQueryOperationDefinitionNode = isLiveQueryOperationDefinitionNode;
