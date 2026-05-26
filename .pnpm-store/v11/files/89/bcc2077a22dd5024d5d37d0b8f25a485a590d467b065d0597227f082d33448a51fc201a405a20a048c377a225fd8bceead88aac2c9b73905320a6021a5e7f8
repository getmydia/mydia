import { ExecutionRequest, DisposableSyncExecutor, DisposableAsyncExecutor } from '@graphql-tools/utils';
import { OperationDefinitionNode, GraphQLResolveInfo, DocumentNode } from 'graphql';

declare const isLiveQueryOperationDefinitionNode: (node: OperationDefinitionNode) => boolean | undefined;

type SyncFetchFn = (url: string, init?: RequestInit, context?: any, info?: GraphQLResolveInfo) => SyncResponse;
type SyncResponse = Omit<Response, 'json' | 'text'> & {
    json: () => any;
    text: () => string;
};
type AsyncFetchFn = (url: string, options?: RequestInit, context?: any, info?: GraphQLResolveInfo) => Promise<Response> | Response;
type RegularFetchFn = (url: string) => Promise<Response> | Response;
type FetchFn = AsyncFetchFn | SyncFetchFn | RegularFetchFn;
type AsyncImportFn = (moduleName: string) => PromiseLike<any>;
type SyncImportFn = (moduleName: string) => any;
interface HTTPExecutorOptions {
    /**
     * The endpoint to use when querying the upstream API. Can also be a factory function that returns the
     * endpoint based on the `ExecutionRequest` allowing for dynamic endpoints, such as using environment
     * variables or other runtime values.
     * @default '/graphql'
     */
    endpoint?: string | ((executorRequest?: ExecutionRequest) => string);
    /**
     * The WHATWG compatible fetch implementation to use
     * @see https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API
     * @default globalThis.fetch
     */
    fetch?: FetchFn;
    /**
     * Whether to use the GET HTTP method for queries when querying the original schema
     * @default false
     */
    useGETForQueries?: boolean;
    /**
     * Whether to use the GET HTTP method for hashed Automatic Persisted Query requests.
     * Full query fallbacks and mutations continue to use POST.
     * @default false
     */
    useGETForHashedQueries?: boolean;
    /**
     * Whether to set `content-type: application/json` on GET requests when one isn't already provided.
     * This can be useful for compatibility with servers that require a preflighted GET request.
     * @default false
     */
    useContentTypeForGETRequests?: boolean;
    /**
     * Additional headers to include when querying the original schema
     */
    headers?: HeadersConfig | ((executorRequest?: ExecutionRequest) => HeadersConfig);
    /**
     * HTTP method to use when querying the original schema.x
     * @default 'POST'
     */
    method?: 'GET' | 'POST';
    /**
     * Timeout in milliseconds
     */
    timeout?: number | ((request: ExecutionRequest) => number | undefined);
    /**
     * Request Credentials
     * @default 'same-origin'
     * @see https://developer.mozilla.org/en-US/docs/Web/API/Request/credentials
     */
    credentials?: RequestCredentials;
    /**
     * Retry attempts
     */
    retry?: number;
    /**
     * WHATWG compatible `File` implementation
     * @see https://developer.mozilla.org/en-US/docs/Web/API/File
     */
    File?: typeof File;
    /**
     * WHATWG compatible `FormData` implementation
     * @see https://developer.mozilla.org/en-US/docs/Web/API/FormData
     */
    FormData?: typeof FormData;
    /**
     * Print function for `DocumentNode`
     * Useful when you want to memoize the print function or use a different implementation to minify the query etc.
     */
    print?: (doc: DocumentNode) => string;
    /**
     * Enable Automatic Persisted Queries
     * @see https://www.apollographql.com/docs/apollo-server/performance/apq/
     */
    apq?: boolean;
    /**
     * Enable Explicit Resource Management
     * @see https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-2.html#using-declarations-and-explicit-resource-management
     * @deprecated The executors are always disposable, and this option will be removed in the next major version, there is no need to have a flag for this.
     */
    disposable?: boolean;
    /**
     * On dispose abort error
     */
    getDisposeReason?(): Error | undefined;
    /**
     * Whether to deduplicate inflight requests with the same parameters.
     * This can be useful to avoid making multiple identical requests to the upstream service when
     * multiple parts of the gateway are requesting the same data at the same time.
     * @default true
     */
    deduplicateInflightRequests?: boolean;
    /**
     * This option allows you to include the response detauls in the result extensions when a request fails.
     * This can be useful for debugging and error handling purposes, as it provides additional context about the response that led to the error.
     * However, be cautious when enabling this option, as response headers may contain sensitive information.
     *
     * @default false
     */
    exposeHTTPDetailsInExtensions?: boolean;
}
type HeadersConfig = Record<string, string>;
interface InflightRequestOptions {
    url: string;
    method: string;
    headers: Record<string, string>;
    body?: string | FormData;
    credentials?: RequestCredentials;
    signal?: AbortSignal;
}
declare function buildHTTPExecutor(options?: Omit<HTTPExecutorOptions, 'fetch'> & {
    fetch: SyncFetchFn;
}): DisposableSyncExecutor<any, HTTPExecutorOptions>;
declare function buildHTTPExecutor(options?: Omit<HTTPExecutorOptions, 'fetch'> & {
    fetch: AsyncFetchFn;
}): DisposableAsyncExecutor<any, HTTPExecutorOptions>;
declare function buildHTTPExecutor(options?: Omit<HTTPExecutorOptions, 'fetch'> & {
    fetch: RegularFetchFn;
}): DisposableAsyncExecutor<any, HTTPExecutorOptions>;
declare function buildHTTPExecutor(options?: Omit<HTTPExecutorOptions, 'fetch'>): DisposableAsyncExecutor<any, HTTPExecutorOptions>;

export { type AsyncFetchFn, type AsyncImportFn, type FetchFn, type HTTPExecutorOptions, type HeadersConfig, type InflightRequestOptions, type RegularFetchFn, type SyncFetchFn, type SyncImportFn, type SyncResponse, buildHTTPExecutor, isLiveQueryOperationDefinitionNode };
