import { SubschemaConfig, Subschema, ICreateProxyingResolverOptions, Transform, DelegationContext } from '@graphql-tools/delegate';
import { GraphQLSchema, GraphQLFieldResolver, GraphQLNamedType, GraphQLEnumValueConfig, GraphQLError, FieldNode, FragmentDefinitionNode, SelectionNode, GraphQLFieldConfig, ObjectValueNode, ObjectFieldNode, GraphQLInputFieldConfig, SelectionSetNode, GraphQLArgument, IntrospectionOptions, buildClientSchema, ParseOptions } from 'graphql';
import { RenameTypesOptions, ExecutionRequest, ExecutionResult, Maybe, RootFieldFilter, ObjectFieldFilter, FieldFilter, InputFieldFilter, PruneSchemaOptions, FieldNodeMappers, SyncExecutor, AsyncExecutor, Executor } from '@graphql-tools/utils';
import { MaybePromise } from '@whatwg-node/promise-helpers';

declare const wrapSchema: <TConfig extends Record<string, any> = Record<string, any>>(subschemaConfig: SubschemaConfig<any, any, any, TConfig> | Subschema<any, any, any, TConfig>) => GraphQLSchema;

declare function generateProxyingResolvers<TContext extends Record<string, any>>(subschemaConfig: SubschemaConfig<any, any, any, TContext>): Record<string, Record<string, GraphQLFieldResolver<any, any>>>;
declare function defaultCreateProxyingResolver<TContext extends Record<string, any>>({ subschemaConfig, operation, }: ICreateProxyingResolverOptions<TContext>): GraphQLFieldResolver<any, any>;

interface RenameTypesTransformationContext extends Record<string, any> {
}
declare class RenameTypes<TContext = Record<string, any>> implements Transform<RenameTypesTransformationContext, TContext> {
    private readonly renamer;
    private map;
    private reverseMap;
    private readonly renameBuiltins;
    private readonly renameScalars;
    constructor(renamer: (name: string) => string | undefined, options?: RenameTypesOptions);
    transformSchema(originalWrappingSchema: GraphQLSchema, _subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, _delegationContext: DelegationContext<TContext>, _transformationContext: RenameTypesTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, _delegationContext: DelegationContext<TContext>, _transformationContext?: RenameTypesTransformationContext): ExecutionResult;
}

interface FilterTypesTransformationContext extends Record<string, any> {
}
declare class FilterTypes<TContext = Record<string, any>> implements Transform<FilterTypesTransformationContext, TContext> {
    private readonly filter;
    constructor(filter: (type: GraphQLNamedType) => boolean);
    transformSchema(originalWrappingSchema: GraphQLSchema, _subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface RenameRootTypesTransformationContext extends Record<string, any> {
}
declare class RenameRootTypes<TContext = Record<string, any>> implements Transform<RenameRootTypesTransformationContext, TContext> {
    private readonly renamer;
    private map;
    private reverseMap;
    constructor(renamer: (name: string) => string | undefined);
    transformSchema(originalWrappingSchema: GraphQLSchema, _subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, _delegationContext: DelegationContext<TContext>, _transformationContext: RenameRootTypesTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, _delegationContext: DelegationContext<TContext>, _transformationContext?: RenameRootTypesTransformationContext): ExecutionResult;
}

type InputFieldTransformer = (typeName: string, fieldName: string, inputFieldConfig: GraphQLInputFieldConfig) => GraphQLInputFieldConfig | [string, GraphQLInputFieldConfig] | null | undefined;
type InputFieldNodeTransformer = <TContext>(typeName: string, fieldName: string, inputFieldNode: ObjectFieldNode, request: ExecutionRequest, delegationContext?: DelegationContext<TContext>) => ObjectFieldNode | Array<ObjectFieldNode>;
type InputObjectNodeTransformer = <TContext>(typeName: string, inputObjectNode: ObjectValueNode, request: ExecutionRequest, delegationContext?: DelegationContext<TContext>) => ObjectValueNode | undefined;
type FieldTransformer<TContext = Record<string, any>> = (typeName: string, fieldName: string, fieldConfig: GraphQLFieldConfig<any, TContext>) => Maybe<GraphQLFieldConfig<any, TContext> | [string, GraphQLFieldConfig<any, TContext>]>;
type RootFieldTransformer<TContext = Record<string, any>> = (operation: 'Query' | 'Mutation' | 'Subscription', fieldName: string, fieldConfig: GraphQLFieldConfig<any, TContext>) => Maybe<GraphQLFieldConfig<any, TContext> | [string, GraphQLFieldConfig<any, TContext>]>;
type EnumValueTransformer = (typeName: string, externalValue: string, enumValueConfig: GraphQLEnumValueConfig) => Maybe<GraphQLEnumValueConfig | [string, GraphQLEnumValueConfig]>;
type FieldNodeTransformer = (typeName: string, fieldName: string, fieldNode: FieldNode, fragments: Record<string, FragmentDefinitionNode>, transformationContext: Record<string, any>) => Maybe<SelectionNode | Array<SelectionNode>>;
type LeafValueTransformer = (typeName: string, value: any) => any;
type DataTransformer = (value: any, transformationContext: Record<string, any>) => any;
type ObjectValueTransformerMap = Record<string, DataTransformer>;
type ErrorsTransformer = (errors: ReadonlyArray<GraphQLError> | undefined, transformationContext: Record<string, any>) => Array<GraphQLError> | undefined;

interface TransformCompositeFieldsTransformationContext extends Record<string, any> {
}
declare class TransformCompositeFields<TContext = Record<string, any>> implements Transform<TransformCompositeFieldsTransformationContext, TContext> {
    private readonly fieldTransformer;
    private readonly fieldNodeTransformer;
    private readonly dataTransformer;
    private readonly errorsTransformer;
    private transformedSchema;
    private typeInfo;
    private mapping;
    private subscriptionTypeName;
    constructor(fieldTransformer: FieldTransformer<TContext>, fieldNodeTransformer?: FieldNodeTransformer, dataTransformer?: DataTransformer, errorsTransformer?: ErrorsTransformer);
    private _getTypeInfo;
    transformSchema(originalWrappingSchema: GraphQLSchema, _subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, _delegationContext: DelegationContext<TContext>, transformationContext: TransformCompositeFieldsTransformationContext): ExecutionRequest;
    transformResult(result: ExecutionResult, _delegationContext: DelegationContext<TContext>, transformationContext: TransformCompositeFieldsTransformationContext): ExecutionResult;
    private transformDocument;
    private transformSelectionSet;
}

interface TransformRootFieldsTransformationContext extends Record<string, any> {
}
declare class TransformRootFields<TContext = Record<string, any>> implements Transform<TransformRootFieldsTransformationContext, TContext> {
    private readonly rootFieldTransformer;
    private readonly fieldNodeTransformer;
    private transformer;
    constructor(rootFieldTransformer: RootFieldTransformer<TContext>, fieldNodeTransformer?: FieldNodeTransformer);
    private _getTransformer;
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: TransformRootFieldsTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: TransformRootFieldsTransformationContext): ExecutionResult;
}

interface RenameRootFieldsTransformationContext extends Record<string, any> {
}
declare class RenameRootFields<TContext = Record<string, any>> implements Transform<RenameRootFieldsTransformationContext, TContext> {
    private readonly transformer;
    constructor(renamer: (operation: 'Query' | 'Mutation' | 'Subscription', name: string, fieldConfig: GraphQLFieldConfig<any, any>) => string);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: RenameRootFieldsTransformationContext): ExecutionRequest;
}

interface FilterRootFieldsTransformationContext extends Record<string, any> {
}
declare class FilterRootFields<TContext = Record<string, any>> implements Transform<FilterRootFieldsTransformationContext, TContext> {
    private readonly transformer;
    constructor(filter: RootFieldFilter);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface TransformObjectFieldsTransformationContext extends Record<string, any> {
}
declare class TransformObjectFields<TContext = Record<string, any>> implements Transform<TransformObjectFieldsTransformationContext, TContext> {
    private readonly objectFieldTransformer;
    private readonly fieldNodeTransformer;
    private transformer;
    constructor(objectFieldTransformer: FieldTransformer<TContext>, fieldNodeTransformer?: FieldNodeTransformer);
    private _getTransformer;
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: TransformObjectFieldsTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: TransformObjectFieldsTransformationContext): ExecutionResult;
}

interface RenameObjectFieldsTransformationContext extends Record<string, any> {
}
declare class RenameObjectFields<TContext = Record<string, any>> implements Transform<RenameObjectFieldsTransformationContext, TContext> {
    private readonly transformer;
    constructor(renamer: (typeName: string, fieldName: string, fieldConfig: GraphQLFieldConfig<any, any>) => string);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: RenameObjectFieldsTransformationContext): ExecutionRequest;
}

type RenamerFunction$1 = (typeName: string, fieldName: string, argName: string) => string;
interface RenameObjectFieldArgumentsTransformationContext extends Record<string, any> {
}
declare class RenameObjectFieldArguments<TContext = Record<string, any>> implements Transform<RenameObjectFieldArgumentsTransformationContext, TContext> {
    private readonly renamer;
    private readonly transformer;
    private reverseMap;
    private transformedSchema;
    constructor(renamer: RenamerFunction$1);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: RenameObjectFieldArgumentsTransformationContext): ExecutionRequest;
}

interface FilterObjectFieldsTransformationContext extends Record<string, any> {
}
declare class FilterObjectFields<TContext = Record<string, any>> implements Transform<FilterObjectFieldsTransformationContext, TContext> {
    private readonly transformer;
    constructor(filter: ObjectFieldFilter);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface TransformInterfaceFieldsTransformationContext extends Record<string, any> {
}
declare class TransformInterfaceFields<TContext = Record<string, any>> implements Transform<TransformInterfaceFieldsTransformationContext, TContext> {
    private readonly interfaceFieldTransformer;
    private readonly fieldNodeTransformer;
    private transformer;
    constructor(interfaceFieldTransformer: FieldTransformer<TContext>, fieldNodeTransformer?: FieldNodeTransformer);
    private _getTransformer;
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: TransformInterfaceFieldsTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: TransformInterfaceFieldsTransformationContext): ExecutionResult;
}

interface RenameInterfaceFieldsTransformationContext extends Record<string, any> {
}
declare class RenameInterfaceFields<TContext = Record<string, any>> implements Transform<RenameInterfaceFieldsTransformationContext, TContext> {
    private readonly transformer;
    constructor(renamer: (typeName: string, fieldName: string, fieldConfig: GraphQLFieldConfig<any, any>) => string);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: RenameInterfaceFieldsTransformationContext): ExecutionRequest;
}

interface FilterInterfaceFieldsTransformationContext extends Record<string, any> {
}
declare class FilterInterfaceFields<TContext = Record<string, any>> implements Transform<FilterInterfaceFieldsTransformationContext, TContext> {
    private readonly transformer;
    constructor(filter: FieldFilter);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface TransformInputObjectFieldsTransformationContext extends Record<string, any> {
}
declare class TransformInputObjectFields<TContext = Record<string, any>> implements Transform<TransformInputObjectFieldsTransformationContext, TContext> {
    private readonly inputFieldTransformer;
    private readonly inputFieldNodeTransformer;
    private readonly inputObjectNodeTransformer;
    private transformedSchema;
    private mapping;
    constructor(inputFieldTransformer: InputFieldTransformer, inputFieldNodeTransformer?: InputFieldNodeTransformer, inputObjectNodeTransformer?: InputObjectNodeTransformer);
    private _getTransformedSchema;
    transformSchema(originalWrappingSchema: GraphQLSchema, _subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, _delegationContext: DelegationContext<TContext>, _transformationContext: TransformInputObjectFieldsTransformationContext): ExecutionRequest;
    private transformDocument;
}

type RenamerFunction = (typeName: string, fieldName: string, inputFieldConfig: GraphQLInputFieldConfig) => string | undefined;
interface RenameInputObjectFieldsTransformationContext extends Record<string, any> {
}
declare class RenameInputObjectFields<TContext = Record<string, any>> implements Transform<RenameInputObjectFieldsTransformationContext, TContext> {
    private readonly renamer;
    private readonly transformer;
    private reverseMap;
    constructor(renamer: RenamerFunction);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: RenameInputObjectFieldsTransformationContext): ExecutionRequest;
}

interface FilterInputObjectFieldsTransformationContext extends Record<string, any> {
}
declare class FilterInputObjectFields<TContext = Record<string, any>> implements Transform<FilterInputObjectFieldsTransformationContext, TContext> {
    private readonly transformer;
    constructor(filter: InputFieldFilter, inputObjectNodeTransformer?: InputObjectNodeTransformer);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: FilterInputObjectFieldsTransformationContext): ExecutionRequest;
}

interface MapLeafValuesTransformationContext {
    transformedRequest: ExecutionRequest;
}
declare class MapLeafValues<TContext = Record<string, any>> implements Transform<MapLeafValuesTransformationContext, TContext> {
    private readonly inputValueTransformer;
    private readonly outputValueTransformer;
    private readonly resultVisitorMap;
    private typeInfo?;
    constructor(inputValueTransformer: LeafValueTransformer, outputValueTransformer: LeafValueTransformer);
    private originalWrappingSchema?;
    transformSchema(originalWrappingSchema: GraphQLSchema, _subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, _delegationContext: DelegationContext<TContext>, transformationContext: MapLeafValuesTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, _delegationContext: DelegationContext<TContext>, transformationContext: MapLeafValuesTransformationContext): ExecutionResult;
    private transformOperations;
    private transformFieldNode;
}

interface TransformEnumValuesTransformationContext extends MapLeafValuesTransformationContext {
}
declare class TransformEnumValues<TContext = Record<string, any>> implements Transform<TransformEnumValuesTransformationContext, TContext> {
    private readonly enumValueTransformer;
    private readonly transformer;
    private transformedSchema;
    private mapping;
    private reverseMapping;
    private noTransformation;
    constructor(enumValueTransformer: EnumValueTransformer, inputValueTransformer?: LeafValueTransformer, outputValueTransformer?: LeafValueTransformer);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: TransformEnumValuesTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: TransformEnumValuesTransformationContext): ExecutionResult<any, any>;
    private transformEnumValue;
}

type QueryTransformer = <TContext>(selectionSet: SelectionSetNode | undefined, fragments: Record<string, FragmentDefinitionNode>, delegationContext: DelegationContext<TContext>, transformationContext: Record<string, any>) => SelectionSetNode;
type ResultTransformer = <TContext>(result: any, delegationContext: DelegationContext<TContext>, transformationContext: Record<string, any>) => any;
type ErrorPathTransformer = (path: ReadonlyArray<string | number>) => Array<string | number>;
interface TransformQueryTransformationContext extends Record<string, any> {
}
declare class TransformQuery<TContext = Record<string, any>> implements Transform<TransformQueryTransformationContext, TContext> {
    private readonly path;
    private readonly queryTransformer;
    private readonly resultTransformer;
    private readonly errorPathTransformer;
    private readonly fragments;
    constructor({ path, queryTransformer, resultTransformer, errorPathTransformer, fragments, }: {
        path: Array<string>;
        queryTransformer: QueryTransformer;
        resultTransformer?: ResultTransformer;
        errorPathTransformer?: ErrorPathTransformer;
        fragments?: Record<string, FragmentDefinitionNode>;
    });
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: TransformQueryTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: TransformQueryTransformationContext): ExecutionResult;
    private transformData;
    private transformErrors;
}

interface FilterObjectFieldDirectivesTransformationContext extends Record<string, any> {
}
declare class FilterObjectFieldDirectives<TContext = Record<string, any>> implements Transform<FilterObjectFieldDirectivesTransformationContext, TContext> {
    private readonly filter;
    constructor(filter: (dirName: string, dirValue: any) => boolean);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface RemoveObjectFieldDirectivesTransformationContext extends Record<string, any> {
}
declare class RemoveObjectFieldDirectives<TContext = Record<string, any>> implements Transform<RemoveObjectFieldDirectivesTransformationContext, TContext> {
    private readonly transformer;
    constructor(directiveName: string | RegExp, args?: Record<string, any>);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface RemoveObjectFieldsWithDirectiveTransformationContext extends Record<string, any> {
}
declare class RemoveObjectFieldsWithDirective<TContext = Record<string, any>> implements Transform<RemoveObjectFieldsWithDirectiveTransformationContext, TContext> {
    private readonly directiveName;
    private readonly args;
    constructor(directiveName: string | RegExp, args?: Record<string, any>);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface RemoveObjectFieldDeprecationsTransformationContext extends Record<string, any> {
}
declare class RemoveObjectFieldDeprecations<TContext = Record<string, any>> implements Transform<RemoveObjectFieldDeprecationsTransformationContext, TContext> {
    private readonly removeDirectives;
    private readonly removeDeprecations;
    constructor(reason: string | RegExp);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface RemoveObjectFieldsWithDeprecationTransformationContext extends Record<string, any> {
}
declare class RemoveObjectFieldsWithDeprecation<TContext = Record<string, any>> implements Transform<RemoveObjectFieldsWithDeprecationTransformationContext, TContext> {
    private readonly transformer;
    constructor(reason: string | RegExp);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface PruneTypesTransformationContext extends Record<string, any> {
}
declare class PruneTypes<TContext = Record<string, any>> implements Transform<PruneTypesTransformationContext, TContext> {
    private readonly options;
    constructor(options?: PruneSchemaOptions);
    transformSchema(originalWrappingSchema: GraphQLSchema, _subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
}

interface WrapTypeTransformationContext extends Record<string, any> {
}
declare class WrapType<TContext extends Record<string, any> = Record<string, any>> implements Transform<WrapTypeTransformationContext, TContext> {
    private readonly transformer;
    constructor(outerTypeName: string, innerTypeName: string, fieldName: string);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: WrapTypeTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: WrapTypeTransformationContext): ExecutionResult;
}

interface WrapFieldsTransformationContext {
    nextIndex: number;
    paths: Record<string, {
        pathToField: Array<string>;
        alias: string;
    }>;
}
interface WrapFieldsConfig {
    isNullable?: boolean;
}
declare class WrapFields<TContext extends Record<string, any>> implements Transform<WrapFieldsTransformationContext, TContext> {
    private readonly outerTypeName;
    private readonly wrappingFieldNames;
    private readonly wrappingTypeNames;
    private readonly numWraps;
    private readonly fieldNames;
    private readonly transformer;
    private readonly config;
    constructor(outerTypeName: string, wrappingFieldNames: Array<string>, wrappingTypeNames: Array<string>, fieldNames?: Array<string>, prefix?: string, config?: WrapFieldsConfig);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: WrapFieldsTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: WrapFieldsTransformationContext): ExecutionResult;
}

interface HoistFieldTransformationContext extends Record<string, any> {
}
declare class HoistField<TContext extends Record<string, any> = Record<string, any>> implements Transform<HoistFieldTransformationContext, TContext> {
    private readonly typeName;
    private readonly newFieldName;
    private readonly pathToField;
    private readonly oldFieldName;
    private readonly argFilters;
    private readonly argLevels;
    private readonly transformer;
    constructor(typeName: string, pathConfig: Array<string | {
        fieldName: string;
        argFilter?: (arg: GraphQLArgument) => boolean;
    }>, newFieldName: string, alias?: string);
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: HoistFieldTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: HoistFieldTransformationContext): ExecutionResult;
}

interface MapFieldsTransformationContext extends Record<string, any> {
}
declare class MapFields<TContext> implements Transform<MapFieldsTransformationContext, TContext> {
    private fieldNodeTransformerMap;
    private objectValueTransformerMap?;
    private errorsTransformer?;
    private transformer;
    constructor(fieldNodeTransformerMap: FieldNodeMappers, objectValueTransformerMap?: ObjectValueTransformerMap, errorsTransformer?: ErrorsTransformer);
    private _getTransformer;
    transformSchema(originalWrappingSchema: GraphQLSchema, subschemaConfig: SubschemaConfig<any, any, any, TContext>): GraphQLSchema;
    transformRequest(originalRequest: ExecutionRequest, delegationContext: DelegationContext<TContext>, transformationContext: MapFieldsTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, delegationContext: DelegationContext<TContext>, transformationContext: MapFieldsTransformationContext): ExecutionResult;
}

type QueryWrapper = (subtree: SelectionSetNode) => SelectionNode | SelectionSetNode;
interface WrapQueryTransformationContext extends Record<string, any> {
}
declare class WrapQuery<TContext = Record<string, any>> implements Transform<WrapQueryTransformationContext, TContext> {
    private readonly path;
    private readonly wrapper;
    private readonly extractor;
    constructor(path: Array<string>, wrapper: QueryWrapper, extractor: (result: any) => any);
    transformRequest(originalRequest: ExecutionRequest, _delegationContext: DelegationContext<TContext>, _transformationContext: WrapQueryTransformationContext): ExecutionRequest;
    transformResult(originalResult: ExecutionResult, _delegationContext: DelegationContext<TContext>, _transformationContext: WrapQueryTransformationContext): ExecutionResult;
}

interface ExtractFieldTransformationContext extends Record<string, any> {
}
declare class ExtractField<TContext = Record<string, any>> implements Transform<ExtractFieldTransformationContext, TContext> {
    private readonly from;
    private readonly to;
    constructor({ from, to }: {
        from: Array<string>;
        to: Array<string>;
    });
    transformRequest(originalRequest: ExecutionRequest, _delegationContext: DelegationContext<TContext>, _transformationContext: ExtractFieldTransformationContext): ExecutionRequest;
}

type SchemaFromExecutorOptions = Partial<IntrospectionOptions> & Parameters<typeof buildClientSchema>[1] & ParseOptions;
declare function schemaFromExecutor(executor: SyncExecutor, context?: Record<string, any>, options?: SchemaFromExecutorOptions): GraphQLSchema;
declare function schemaFromExecutor(executor: AsyncExecutor, context?: Record<string, any>, options?: SchemaFromExecutorOptions): Promise<GraphQLSchema>;
declare function schemaFromExecutor(executor: Executor, context?: Record<string, any>, options?: SchemaFromExecutorOptions): MaybePromise<GraphQLSchema>;

export { type DataTransformer, type EnumValueTransformer, type ErrorsTransformer, ExtractField, type FieldNodeTransformer, type FieldTransformer, FilterInputObjectFields, FilterInterfaceFields, FilterObjectFieldDirectives, FilterObjectFields, FilterRootFields, FilterTypes, HoistField, type InputFieldNodeTransformer, type InputFieldTransformer, type InputObjectNodeTransformer, type LeafValueTransformer, MapFields, MapLeafValues, type ObjectValueTransformerMap, PruneTypes as PruneSchema, RemoveObjectFieldDeprecations, RemoveObjectFieldDirectives, RemoveObjectFieldsWithDeprecation, RemoveObjectFieldsWithDirective, RenameInputObjectFields, RenameInterfaceFields, RenameObjectFieldArguments, RenameObjectFields, RenameRootFields, RenameRootTypes, RenameTypes, type RootFieldTransformer, type SchemaFromExecutorOptions, TransformCompositeFields, TransformEnumValues, TransformInputObjectFields, TransformInterfaceFields, TransformObjectFields, TransformQuery, TransformRootFields, WrapFields, WrapQuery, WrapType, defaultCreateProxyingResolver, generateProxyingResolvers, schemaFromExecutor, wrapSchema };
