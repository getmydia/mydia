import { ExecutionRequest } from '@graphql-tools/utils';
import { DocumentNode } from 'graphql';

declare const defaultPrintFn: (document: DocumentNode) => string;
interface ExecutionRequestToGraphQLParams {
    executionRequest: ExecutionRequest;
    excludeQuery?: boolean;
    printFn?: typeof defaultPrintFn;
}
interface SerializedExecutionRequest {
    query?: string | undefined;
    variables?: Record<string, any>;
    operationName?: string;
    extensions?: Record<string, any>;
}
declare function serializeExecutionRequest(opts: Omit<ExecutionRequestToGraphQLParams, 'excludeQuery'> & {
    excludeQuery: true;
}): Omit<SerializedExecutionRequest, 'query'>;
declare function serializeExecutionRequest(opts: Omit<ExecutionRequestToGraphQLParams, 'excludeQuery'> & {
    excludeQuery?: false;
}): Omit<SerializedExecutionRequest, 'query'> & {
    query: string;
};
declare function serializeExecutionRequest(opts: ExecutionRequestToGraphQLParams): SerializedExecutionRequest;
interface UpstreamErrorExtensions {
    code?: string;
    serviceName?: string;
    request: {
        url?: string;
        method?: string;
        body?: unknown;
    };
    response?: {
        status?: number;
        statusText?: string;
        headers?: Record<string, string>;
        body?: unknown;
    };
}

export { type SerializedExecutionRequest, type UpstreamErrorExtensions, defaultPrintFn, serializeExecutionRequest };
