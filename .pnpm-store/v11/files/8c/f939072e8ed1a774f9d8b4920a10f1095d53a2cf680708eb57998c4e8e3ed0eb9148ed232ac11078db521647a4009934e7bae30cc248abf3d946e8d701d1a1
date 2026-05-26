import { ExecutionRequest, ExecutionResult, Executor, Maybe, GraphQLResolveInfo as GraphQLResolveInfo$1 } from '@graphql-tools/utils';
export { createDeferred } from '@graphql-tools/utils';
import * as graphql from 'graphql';
import { GraphQLSchema, OperationTypeNode, GraphQLResolveInfo, GraphQLOutputType, GraphQLError, SelectionSetNode, GraphQLFieldResolver, FragmentDefinitionNode, FieldNode, GraphQLNamedType, GraphQLObjectType, GraphQLField, GraphQLInterfaceType, SelectionNode, GraphQLNamedOutputType, TypeInfo, GraphQLType } from 'graphql';
import DataLoader from 'dataloader';
import { MaybePromise } from '@whatwg-node/promise-helpers';
export { executorFromSchema as createDefaultExecutor } from '@graphql-tools/executor';

declare const UNPATHED_ERRORS_SYMBOL: unique symbol;
declare const OBJECT_SUBSCHEMA_SYMBOL: unique symbol;
declare const FIELD_SUBSCHEMA_MAP_SYMBOL: unique symbol;

type SchemaTransform<TContext = Record<any, string>> = (originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>) => GraphQLSchema;
type RequestTransform<T = Record<string, any>, TContext = Record<any, string>> = (originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: T) => ExecutionRequest;
type ResultTransform<T = Record<string, any>, TContext = Record<any, string>> = (originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: T) => ExecutionResult;
interface Transform<T = any, TContext = Record<string, any>> {
    transformSchema?: SchemaTransform<TContext>;
    transformRequest?: RequestTransform<T, TContext>;
    transformResult?: ResultTransform<T, TContext>;
}
interface DelegationContext<TContext = Record<string, any>> {
    subschema: GraphQLSchema | SubschemaConfig<any, any, any, TContext>;
    subschemaConfig?: SubschemaConfig<any, any, any, TContext>;
    targetSchema: GraphQLSchema;
    operation: OperationTypeNode;
    fieldName: string;
    args?: Record<string, any>;
    context?: TContext;
    info?: GraphQLResolveInfo;
    returnType: GraphQLOutputType;
    onLocatedError?: (originalError: GraphQLError) => GraphQLError;
    rootValue?: any;
    transforms: Array<Transform<any, TContext>>;
    transformedSchema: GraphQLSchema;
    skipTypeMerging: boolean;
}
interface IDelegateToSchemaOptions<TContext = Record<string, any>, TArgs = Record<string, any>> {
    schema: GraphQLSchema | SubschemaConfig<any, any, any, TContext>;
    operationName?: string;
    operation?: OperationTypeNode;
    fieldName?: string;
    returnType?: GraphQLOutputType;
    onLocatedError?: (originalError: GraphQLError) => GraphQLError;
    args?: TArgs;
    selectionSet?: SelectionSetNode;
    fieldNodes?: ReadonlyArray<FieldNode>;
    context?: TContext;
    info: GraphQLResolveInfo;
    rootValue?: any;
    transforms?: Array<Transform<any, TContext>>;
    targetSchema?: GraphQLSchema;
    validateRequest?: boolean;
    skipTypeMerging?: boolean;
}
interface IDelegateRequestOptions<TContext = Record<string, any>, TArgs = Record<string, any>> extends IDelegateToSchemaOptions<TContext, TArgs> {
    request: ExecutionRequest;
    targetSchema: GraphQLSchema;
}
interface ICreateRequest {
    subgraphName: string | undefined;
    fragments?: FragmentDefinitionNode[];
    targetOperation: OperationTypeNode;
    targetOperationName?: string;
    targetFieldName: string;
    targetSchema: GraphQLSchema;
    selectionSet?: SelectionSetNode;
    fieldNodes?: ReadonlyArray<FieldNode>;
    rootValue?: any;
    args?: Record<string, any>;
    context?: any;
    info?: GraphQLResolveInfo;
}
type DelegationPlanBuilder = (schema: GraphQLSchema, sourceSubschema: Subschema<any, any, any, any>, variableValues: Record<string, any>, fragments: Record<string, FragmentDefinitionNode>, fieldNodes: FieldNode[], context?: any, info?: GraphQLResolveInfo) => Array<Map<Subschema, SelectionSetNode>>;
interface MergedTypeInfo<TContext = Record<string, any>> {
    typeName: string;
    selectionSet?: SelectionSetNode;
    targetSubschemas: Map<Subschema<any, any, any, TContext>, Array<Subschema<any, any, any, TContext>>>;
    uniqueFields: Record<string, Subschema<any, any, any, TContext>>;
    nonUniqueFields: Record<string, Array<Subschema<any, any, any, TContext>>>;
    typeMaps: Map<GraphQLSchema | SubschemaConfig<any, any, any, TContext>, Record<string, GraphQLNamedType>>;
    selectionSets: Map<Subschema<any, any, any, TContext>, SelectionSetNode>;
    fieldSelectionSets: Map<Subschema<any, any, any, TContext>, Record<string, SelectionSetNode>>;
    resolvers: Map<Subschema<any, any, any, TContext>, MergedTypeResolver<TContext>>;
    providedSelectionsByField: Map<Subschema<any, any, any, TContext>, Record<string, SelectionSetNode>>;
    delegationPlanBuilder: DelegationPlanBuilder;
    nonMemoizedDelegationPlanBuilder: DelegationPlanBuilder;
}
interface ICreateProxyingResolverOptions<TContext = Record<string, any>> {
    subschemaConfig: SubschemaConfig<any, any, any, TContext>;
    operation?: OperationTypeNode;
    fieldName?: string;
}
type CreateProxyingResolverFn<TContext = Record<string, any>> = (options: ICreateProxyingResolverOptions<TContext>) => GraphQLFieldResolver<any, TContext>;
interface BatchingOptions<K = any, V = any, C = K> {
    extensionsReducer?: (mergedExtensions: Record<string, any>, request: ExecutionRequest) => Record<string, any>;
    dataLoaderOptions?: DataLoader.Options<K, V, C>;
}
interface SubschemaConfig<K = any, V = any, C = K, TContext = Record<string, any>> {
    name?: string;
    schema: GraphQLSchema;
    createProxyingResolver?: CreateProxyingResolverFn<TContext>;
    rootValue?: any;
    transforms?: Array<Transform<any, TContext>>;
    merge?: Record<string, MergedTypeConfig<any, any, TContext>>;
    executor?: Executor<TContext>;
    batch?: boolean;
    batchingOptions?: BatchingOptions<K, V, C>;
}
interface MergedTypeConfig<K = any, V = any, TContext = Record<string, any>> extends MergedTypeEntryPoint<K, V, TContext> {
    entryPoints?: Array<MergedTypeEntryPoint>;
    fields?: Record<string, MergedFieldConfig>;
    canonical?: boolean;
}
interface MergedTypeEntryPoint<K = any, V = any, TContext = Record<string, any>> extends MergedTypeResolverOptions<K, V> {
    selectionSet?: string;
    key?: (originalResult: any) => K | PromiseLike<K>;
    resolve?: MergedTypeResolver<TContext>;
}
interface MergedTypeResolverOptions<K = any, V = any> {
    fieldName?: string;
    args?: (originalResult: any) => Record<string, any>;
    argsFromKeys?: (keys: ReadonlyArray<K>) => Record<string, any>;
    valuesFromResults?: (results: any, keys: ReadonlyArray<K>) => Array<V>;
    dataLoaderOptions?: DataLoader.Options<K, V>;
}
type OverrideHandler = (context: any, info: GraphQLResolveInfo) => boolean;
interface MergedFieldConfig {
    selectionSet?: string;
    computed?: boolean;
    canonical?: boolean;
    provides?: SelectionSetNode;
    override?: OverrideHandler;
}
type MergedTypeResolver<TContext = Record<string, any>> = (originalResult: any, context: TContext, info: GraphQLResolveInfo, subschema: Subschema<any, any, any, TContext>, selectionSet: SelectionSetNode, key: any | undefined, type: GraphQLOutputType) => any;
interface StitchingInfo<TContext = Record<string, any>> {
    subschemaMap: Map<GraphQLSchema | SubschemaConfig<any, any, any, TContext>, Subschema<any, any, any, TContext>>;
    fieldNodesByType: Record<string, Array<FieldNode>>;
    fieldNodesByField: Record<string, Record<string, Array<FieldNode>>>;
    dynamicSelectionSetsByField: Record<string, Record<string, Array<(node: FieldNode) => SelectionSetNode>>>;
    mergedTypes: Record<string, MergedTypeInfo<TContext>>;
}
interface ExternalObject<TContext = Record<string, any>> {
    __typename: string;
    key: any;
    [OBJECT_SUBSCHEMA_SYMBOL]: GraphQLSchema | SubschemaConfig<any, any, any, TContext>;
    [FIELD_SUBSCHEMA_MAP_SYMBOL]: Record<string, GraphQLSchema | SubschemaConfig<any, any, any, TContext>>;
    [UNPATHED_ERRORS_SYMBOL]: Array<GraphQLError>;
    [key: string]: unknown;
}

declare function isSubschema(value: any): value is Subschema;
interface ISubschema<K = any, V = any, C = K, TContext = Record<string, any>> extends SubschemaConfig<K, V, C, TContext> {
    transformedSchema: GraphQLSchema;
}
declare class Subschema<K = any, V = any, C = K, TContext = Record<string, any>> implements ISubschema<K, V, C, TContext> {
    name?: string;
    schema: GraphQLSchema;
    executor?: Executor<TContext>;
    batch?: boolean;
    batchingOptions?: BatchingOptions<K, V, C>;
    createProxyingResolver?: CreateProxyingResolverFn<TContext>;
    transforms: Array<Transform<any, TContext>>;
    private _transformedSchema;
    merge?: Record<string, MergedTypeConfig<any, any, TContext>>;
    constructor(config: SubschemaConfig<K, V, C, TContext>);
    get transformedSchema(): GraphQLSchema;
    set transformedSchema(value: GraphQLSchema);
}

declare class Transformer<TContext extends Record<string, any> = Record<string, any>> {
    private transformations;
    private delegationContext;
    private hasOverlappingAliases;
    constructor(context: DelegationContext<TContext>);
    private addTransform;
    transformRequest(originalRequest: ExecutionRequest): ExecutionRequest;
    transformResult(originalResult: ExecutionResult): any;
}

declare const applySchemaTransforms: (originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, any>) => GraphQLSchema;

declare function getDelegatingOperation(parentType: GraphQLObjectType, schema: GraphQLSchema): OperationTypeNode;
declare function createRequest({ subgraphName, fragments, rootValue, targetOperationName, targetOperation, targetSchema, targetFieldName, selectionSet, fieldNodes, context, info, args, }: ICreateRequest): ExecutionRequest;

/**
 * Resolver that knows how to:
 * a) handle aliases for proxied schemas
 * b) handle errors from proxied schemas
 * c) handle external to internal enum conversion
 */
declare function defaultMergedResolver(parent: ExternalObject, args: Record<string, any>, context: Record<string, any>, info: GraphQLResolveInfo): any;

declare function delegateToSchema<TContext extends Record<string, any> = Record<string, any>, TArgs extends Record<string, any> = any>(options: IDelegateToSchemaOptions<TContext, TArgs>): any;
declare function delegateRequest<TContext extends Record<string, any> = Record<string, any>, TArgs extends Record<string, any> = any>(options: IDelegateRequestOptions<TContext, TArgs>): any;

declare function isExternalObject(data: any): data is ExternalObject;
declare function annotateExternalObject<TContext>(object: any, errors: Array<GraphQLError>, subschema: GraphQLSchema | SubschemaConfig<any, any, any, TContext> | undefined, subschemaMap: Record<string, GraphQLSchema | SubschemaConfig<any, any, any, Record<string, any>>>): ExternalObject;
declare function getSubschema(object: ExternalObject, responseKey: string): GraphQLSchema | SubschemaConfig;
declare function getUnpathedErrors(object: ExternalObject): Array<GraphQLError>;
declare const EMPTY_ARRAY: any[];
declare const EMPTY_OBJECT: any;
declare const getActualFieldNodes: (fieldNode: FieldNode) => FieldNode[];
declare function mergeFields<TContext>(mergedTypeInfo: MergedTypeInfo, object: any, sourceSubschema: Subschema<any, any, any, TContext>, context: any, info: GraphQLResolveInfo): MaybePromise<any>;
declare function handleResolverResult(resolverResult: any, subschema: Subschema, selectionSet: SelectionSetNode, object: ExternalObject, combinedFieldSubschemaMap: Record<string, GraphQLSchema | SubschemaConfig<any, any, any, Record<string, any>>>, info: GraphQLResolveInfo, path: Array<string | number>, combinedErrors: Array<GraphQLError>): void;

declare function resolveExternalValue<TContext extends Record<string, any>>(result: any, unpathedErrors: Array<GraphQLError>, subschema: GraphQLSchema | SubschemaConfig<any, any, any, TContext>, context?: Record<string, any>, info?: GraphQLResolveInfo, returnType?: GraphQLOutputType, skipTypeMerging?: boolean): any;

declare function isSubschemaConfig(value: any): value is SubschemaConfig<any, any, any, any>;
declare function cloneSubschemaConfig(subschemaConfig: SubschemaConfig): SubschemaConfig;

declare function extractUnavailableFieldsFromSelectionSet(schema: GraphQLSchema, fieldType: GraphQLNamedOutputType, fieldSelectionSet: SelectionSetNode, shouldAdd: (fieldType: GraphQLObjectType | GraphQLInterfaceType, selection: FieldNode) => boolean, fragments?: Record<string, FragmentDefinitionNode>): SelectionNode[];
declare function extractUnavailableFields(schema: GraphQLSchema, field: GraphQLField<any, any>, fieldNode: FieldNode, shouldAdd: (fieldType: GraphQLObjectType | GraphQLInterfaceType, selection: FieldNode) => boolean, fragments?: Record<string, FragmentDefinitionNode>): SelectionNode[];
declare function subtractSelectionSets(selectionSetA: SelectionSetNode, selectionSetB: SelectionSetNode): SelectionSetNode;

type Deferred<T = unknown> = {
    promise: Promise<T>;
    resolve: (value: T | PromiseLike<T>) => void;
    reject: (reason?: any) => void;
};

interface DelegationPlanLeftOver {
    unproxiableFieldNodes: Array<FieldNode>;
    nonProxiableSubschemas: Array<Subschema>;
    missingFieldsParentMap: Map<ExternalObject, Array<FieldNode>>;
    missingFieldsParentDeferredMap: Map<ExternalObject, Map<string, Deferred>>;
}
declare const leftOverByDelegationPlan: WeakMap<Map<Subschema<any, any, any, Record<string, any>>, graphql.SelectionSetNode>[], DelegationPlanLeftOver>;
declare const PLAN_LEFT_OVER: symbol;
declare function getPlanLeftOverFromParent(parent: any): DelegationPlanLeftOver | undefined;

declare const getTypeInfo: (schema: GraphQLSchema) => TypeInfo;
declare const getTypeInfoWithType: (schema: GraphQLSchema, type: Maybe<GraphQLType>) => TypeInfo;

declare const prototypePollutingKeys: readonly ["__proto__", "constructor", "prototype"];
type PrototypePollutingKey = (typeof prototypePollutingKeys)[number];
declare function isPrototypePollutingKey(key: string): key is PrototypePollutingKey;

declare const handleOverrideByDelegation: (info: GraphQLResolveInfo$1, context: any, overrideHandler: OverrideHandler) => boolean;

export { type BatchingOptions, type CreateProxyingResolverFn, type Deferred, type DelegationContext, type DelegationPlanBuilder, type DelegationPlanLeftOver, EMPTY_ARRAY, EMPTY_OBJECT, type ExternalObject, FIELD_SUBSCHEMA_MAP_SYMBOL, type ICreateProxyingResolverOptions, type ICreateRequest, type IDelegateRequestOptions, type IDelegateToSchemaOptions, type MergedFieldConfig, type MergedTypeConfig, type MergedTypeEntryPoint, type MergedTypeInfo, type MergedTypeResolver, type MergedTypeResolverOptions, OBJECT_SUBSCHEMA_SYMBOL, type OverrideHandler, PLAN_LEFT_OVER, type RequestTransform, type ResultTransform, type SchemaTransform, type StitchingInfo, Subschema, type SubschemaConfig, type Transform, Transformer, UNPATHED_ERRORS_SYMBOL, annotateExternalObject, applySchemaTransforms, cloneSubschemaConfig, createRequest, defaultMergedResolver, delegateRequest, delegateToSchema, extractUnavailableFields, extractUnavailableFieldsFromSelectionSet, getActualFieldNodes, getDelegatingOperation, getPlanLeftOverFromParent, getSubschema, getTypeInfo, getTypeInfoWithType, getUnpathedErrors, handleOverrideByDelegation, handleResolverResult, isExternalObject, isPrototypePollutingKey, isSubschema, isSubschemaConfig, leftOverByDelegationPlan, mergeFields, resolveExternalValue, subtractSelectionSets };
