import { Executor, ExecutionRequest, MaybeAsyncIterable } from '@graphql-tools/utils';
import DataLoader from 'dataloader';

declare function createBatchingExecutor(executor: Executor, dataLoaderOptions?: DataLoader.Options<ExecutionRequest, MaybeAsyncIterable<any>>, extensionsReducer?: (mergedExtensions: Record<string, any>, request: ExecutionRequest) => Record<string, any>): Executor;

declare const getBatchingExecutor: (_context: Record<string, any>, executor: Executor, dataLoaderOptions?: DataLoader.Options<any, any, any> | undefined, extensionsReducer?: undefined | ((mergedExtensions: Record<string, any>, request: ExecutionRequest) => Record<string, any>)) => Executor;

export { createBatchingExecutor, getBatchingExecutor };
