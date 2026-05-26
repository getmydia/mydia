"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.UrlLoader = exports.SubscriptionProtocol = void 0;
const tslib_1 = require("tslib");
const graphql_1 = require("graphql");
const isomorphic_ws_1 = tslib_1.__importDefault(require("isomorphic-ws"));
const executor_graphql_ws_1 = require("@graphql-tools/executor-graphql-ws");
const executor_http_1 = require("@graphql-tools/executor-http");
const executor_legacy_ws_1 = require("@graphql-tools/executor-legacy-ws");
const utils_1 = require("@graphql-tools/utils");
const wrap_1 = require("@graphql-tools/wrap");
const promise_helpers_1 = require("@whatwg-node/promise-helpers");
const defaultAsyncFetch_js_1 = require("./defaultAsyncFetch.js");
const defaultSyncFetch_js_1 = require("./defaultSyncFetch.js");
const asyncImport = (moduleName) => Promise.resolve(`${`${moduleName}`}`).then(s => tslib_1.__importStar(require(s)));
// eslint-disable-next-line @typescript-eslint/no-require-imports
const syncImport = (moduleName) => require(`${moduleName}`);
var SubscriptionProtocol;
(function (SubscriptionProtocol) {
    SubscriptionProtocol["WS"] = "WS";
    /**
     * Use legacy web socket protocol `graphql-ws` instead of the more current standard `graphql-transport-ws`
     */
    SubscriptionProtocol["LEGACY_WS"] = "LEGACY_WS";
    /**
     * Use SSE for subscription instead of WebSocket
     */
    SubscriptionProtocol["SSE"] = "SSE";
    /**
     * Use `graphql-sse` for subscriptions
     */
    SubscriptionProtocol["GRAPHQL_SSE"] = "GRAPHQL_SSE";
})(SubscriptionProtocol || (exports.SubscriptionProtocol = SubscriptionProtocol = {}));
const acceptableProtocols = ['http:', 'https:', 'ws:', 'wss:'];
function isCompatibleUri(uri) {
    if (acceptableProtocols.some(protocol => uri.startsWith(protocol))) {
        return (0, utils_1.isUrl)(uri);
    }
    return false;
}
/**
 * This loader loads a schema from a URL. The loaded schema is a fully-executable,
 * remote schema since it's created using [@graphql-tools/wrap](/docs/remote-schemas).
 *
 * ```
 * const schema = await loadSchema('http://localhost:3000/graphql', {
 *   loaders: [
 *     new UrlLoader(),
 *   ]
 * });
 * ```
 */
class UrlLoader {
    buildHTTPExecutor(initialEndpoint, fetchFn, options) {
        const HTTP_URL = switchProtocols(initialEndpoint, {
            wss: 'https',
            ws: 'http',
        });
        return (0, executor_http_1.buildHTTPExecutor)({
            endpoint: HTTP_URL,
            fetch: fetchFn,
            ...options,
        });
    }
    buildWSExecutor(subscriptionsEndpoint, webSocketImpl, connectionParams) {
        const WS_URL = switchProtocols(subscriptionsEndpoint, {
            https: 'wss',
            http: 'ws',
        });
        const opts = {
            url: WS_URL,
            webSocketImpl,
            connectionParams,
        };
        return (0, executor_graphql_ws_1.buildGraphQLWSExecutor)(opts);
    }
    buildWSLegacyExecutor(subscriptionsEndpoint, WebSocketImpl, options) {
        const WS_URL = switchProtocols(subscriptionsEndpoint, {
            https: 'wss',
            http: 'ws',
        });
        return (0, executor_legacy_ws_1.buildWSLegacyExecutor)(WS_URL, WebSocketImpl, options);
    }
    getFetch(customFetch, importFn) {
        if (customFetch) {
            if (typeof customFetch === 'string') {
                const [moduleName, fetchFnName] = customFetch.split('#');
                return (0, promise_helpers_1.handleMaybePromise)(() => importFn(moduleName), module => (fetchFnName ? module[fetchFnName] : module));
            }
            else if (typeof customFetch === 'function') {
                return customFetch;
            }
        }
        if (importFn === asyncImport) {
            return defaultAsyncFetch_js_1.defaultAsyncFetch;
        }
        else {
            return defaultSyncFetch_js_1.defaultSyncFetch;
        }
    }
    getDefaultMethodFromOptions(method, defaultMethod) {
        if (method) {
            defaultMethod = method;
        }
        return defaultMethod;
    }
    getWebSocketImpl(importFn, options) {
        if (typeof options?.webSocketImpl === 'string') {
            const [moduleName, webSocketImplName] = options.webSocketImpl.split('#');
            return (0, promise_helpers_1.handleMaybePromise)(() => importFn(moduleName), importedModule => (webSocketImplName ? importedModule[webSocketImplName] : importedModule));
        }
        else {
            const websocketImpl = options?.webSocketImpl || isomorphic_ws_1.default;
            return websocketImpl;
        }
    }
    buildSubscriptionExecutor(subscriptionsEndpoint, fetch, importFn, options) {
        if (options?.subscriptionsProtocol === SubscriptionProtocol.SSE) {
            return this.buildHTTPExecutor(subscriptionsEndpoint, fetch, options);
        }
        else if (options?.subscriptionsProtocol === SubscriptionProtocol.GRAPHQL_SSE) {
            if (!options?.subscriptionsEndpoint) {
                // when no custom subscriptions endpoint is specified,
                // graphql-sse is recommended to be used on `/graphql/stream`
                subscriptionsEndpoint += '/stream';
            }
            return this.buildHTTPExecutor(subscriptionsEndpoint, fetch, options);
        }
        else {
            return request => (0, promise_helpers_1.handleMaybePromise)(() => (0, promise_helpers_1.handleMaybePromise)(() => this.getWebSocketImpl(importFn, options), webSocketImpl => {
                if (options?.subscriptionsProtocol === SubscriptionProtocol.LEGACY_WS) {
                    return this.buildWSLegacyExecutor(subscriptionsEndpoint, webSocketImpl, options);
                }
                else {
                    return this.buildWSExecutor(subscriptionsEndpoint, webSocketImpl, options?.connectionParams);
                }
            }), executor => executor(request));
        }
    }
    getExecutor(endpoint, importFn, options) {
        let fetch$;
        const getHttpExecutor = () => {
            return (0, promise_helpers_1.handleMaybePromise)(() => (fetch$ ||= this.getFetch(options?.customFetch, importFn)), fetch => this.buildHTTPExecutor(endpoint, fetch, options));
        };
        const getSetHttpExecutor$ = () => (httpExecutor$ ||= getHttpExecutor());
        let httpExecutor$;
        if (options?.subscriptionsEndpoint != null ||
            options?.subscriptionsProtocol !== SubscriptionProtocol.SSE) {
            const subscriptionExecutor$ = (0, promise_helpers_1.handleMaybePromise)(() => (fetch$ ||= this.getFetch(options?.customFetch, importFn)), fetch => {
                const subscriptionsEndpoint = options?.subscriptionsEndpoint || endpoint;
                return this.buildSubscriptionExecutor(subscriptionsEndpoint, fetch, importFn, options);
            });
            function getExecutorByRequest(request) {
                request.operationType =
                    request.operationType || (0, utils_1.getOperationASTFromRequest)(request)?.operation;
                if (request.operationType === 'subscription' &&
                    (0, executor_http_1.isLiveQueryOperationDefinitionNode)((0, utils_1.getOperationASTFromRequest)(request))) {
                    request.operationType = 'subscription';
                }
                if (request.operationType === 'subscription') {
                    return subscriptionExecutor$;
                }
                else {
                    return getSetHttpExecutor$();
                }
            }
            return request => (0, promise_helpers_1.handleMaybePromise)(() => getExecutorByRequest(request), executor => executor(request));
        }
        else {
            return request => (0, promise_helpers_1.handleMaybePromise)(getSetHttpExecutor$, executor => executor(request));
        }
    }
    getExecutorAsync(endpoint, options) {
        return this.getExecutor(endpoint, asyncImport, options);
    }
    getExecutorSync(endpoint, options) {
        return this.getExecutor(endpoint, syncImport, options);
    }
    handleSDL(pointer, fetch, options) {
        const defaultMethod = this.getDefaultMethodFromOptions(options?.method, 'GET');
        return (0, promise_helpers_1.handleMaybePromise)(() => fetch(pointer, {
            method: defaultMethod,
            headers: typeof options?.headers === 'function' ? options.headers() : options?.headers,
        }), res => (0, promise_helpers_1.handleMaybePromise)(() => res.text(), schemaString => (0, utils_1.parseGraphQLSDL)(pointer, schemaString, options)));
    }
    async load(pointer, options) {
        if (!isCompatibleUri(pointer)) {
            return [];
        }
        let source = {
            location: pointer,
        };
        let executor;
        if (options?.handleAsSDL || pointer.endsWith('.graphql') || pointer.endsWith('.graphqls')) {
            const fetch = await this.getFetch(options?.customFetch, asyncImport);
            source = await this.handleSDL(pointer, fetch, options);
            if (!source.schema && !source.document && !source.rawSDL) {
                throw new Error(`Invalid SDL response`);
            }
            source.schema =
                source.schema ||
                    (source.document
                        ? (0, graphql_1.buildASTSchema)(source.document, options)
                        : source.rawSDL
                            ? (0, graphql_1.buildSchema)(source.rawSDL, options)
                            : undefined);
        }
        else {
            executor = this.getExecutorAsync(pointer, options);
            source.schema = await (0, wrap_1.schemaFromExecutor)(executor, {}, options);
        }
        if (!source.schema) {
            throw new Error(`Invalid introspected schema`);
        }
        if (options?.endpoint) {
            executor = this.getExecutorAsync(options.endpoint, options);
        }
        if (executor) {
            source.schema = (0, wrap_1.wrapSchema)({
                schema: source.schema,
                executor,
                batch: options?.batch,
            });
        }
        return [source];
    }
    loadSync(pointer, options) {
        if (!isCompatibleUri(pointer)) {
            return [];
        }
        let source = {
            location: pointer,
        };
        let executor;
        if (options?.handleAsSDL || pointer.endsWith('.graphql') || pointer.endsWith('.graphqls')) {
            const fetch = this.getFetch(options?.customFetch, syncImport);
            source = this.handleSDL(pointer, fetch, options);
            if (!source.schema && !source.document && !source.rawSDL) {
                throw new Error(`Invalid SDL response`);
            }
            source.schema =
                source.schema ||
                    (source.document
                        ? (0, graphql_1.buildASTSchema)(source.document, options)
                        : source.rawSDL
                            ? (0, graphql_1.buildSchema)(source.rawSDL, options)
                            : undefined);
        }
        else {
            executor = this.getExecutorSync(pointer, options);
            source.schema = (0, wrap_1.schemaFromExecutor)(executor, {}, options);
        }
        if (!source.schema) {
            throw new Error(`Invalid introspected schema`);
        }
        if (options?.endpoint) {
            executor = this.getExecutorSync(options.endpoint, options);
        }
        if (executor) {
            source.schema = (0, wrap_1.wrapSchema)({
                schema: source.schema,
                executor,
            });
        }
        return [source];
    }
}
exports.UrlLoader = UrlLoader;
function switchProtocols(pointer, protocolMap) {
    return Object.entries(protocolMap).reduce((prev, [source, target]) => prev.replace(`${source}://`, `${target}://`).replace(`${source}:\\`, `${target}:\\`), pointer);
}
