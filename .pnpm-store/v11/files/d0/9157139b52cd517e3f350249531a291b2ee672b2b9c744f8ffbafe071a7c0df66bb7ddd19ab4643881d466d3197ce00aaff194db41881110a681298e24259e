import { ASTNode, DirectiveDefinitionNode, EnumTypeDefinitionNode, FieldDefinitionNode, GraphQLInterfaceType, GraphQLNamedType, GraphQLObjectType, GraphQLSchema, GraphQLUnionType, InputValueDefinitionNode, InterfaceTypeDefinitionNode, ListTypeNode, NamedTypeNode, NonNullTypeNode, ObjectTypeDefinitionNode, ScalarTypeDefinitionNode, UnionTypeDefinitionNode } from 'graphql';
import { ApolloFederation, type FederationMeta } from '@graphql-codegen/plugin-helpers';
import { BaseVisitor, BaseVisitorConvertOptions, ParsedConfig, RawConfig } from './base-visitor.js';
import { ParsedMapper } from './mappers.js';
import { AvoidOptionalsConfig, ConvertOptions, DeclarationKind, EnumValuesMap, NormalizedAvoidOptionalsConfig, NormalizedScalarsMap, ParsedEnumValuesMap, ResolversNonOptionalTypenameConfig } from './types.js';
import { DeclarationBlockConfig } from './utils.js';
import { OperationVariablesToObject } from './variables-to-object.js';
export interface ParsedResolversConfig extends ParsedConfig {
    contextType: ParsedMapper;
    fieldContextTypes: Array<string>;
    directiveContextTypes: Array<string>;
    rootValueType: ParsedMapper;
    mappers: {
        [typeName: string]: ParsedMapper;
    };
    defaultMapper: ParsedMapper | null;
    avoidOptionals: NormalizedAvoidOptionalsConfig;
    addUnderscoreToArgsType: boolean;
    addInterfaceFieldResolverTypes: boolean;
    enumValues: ParsedEnumValuesMap;
    resolverTypeWrapperSignature: string;
    federation: boolean;
    enumPrefix: boolean;
    enumSuffix: boolean;
    optionalResolveType: boolean;
    immutableTypes: boolean;
    namespacedImportName: string;
    resolverTypeSuffix: string;
    allResolversTypeName: string;
    internalResolversPrefix: string;
    directiveResolverMappings: Record<string, string>;
    resolversNonOptionalTypename: ResolversNonOptionalTypenameConfig;
    avoidCheckingAbstractTypesRecursively: boolean;
}
export interface FieldDefinitionResult {
    node: FieldDefinitionNode;
    printContent: FieldDefinitionPrintFn;
}
type FieldDefinitionPrintFn = (parentNode: ObjectTypeDefinitionNode | InterfaceTypeDefinitionNode, avoidResolverOptionals: boolean) => {
    value: string | null;
    meta: {
        federation?: {
            isResolveReference: boolean;
        };
    };
};
export interface RootResolver {
    content: string;
    generatedResolverTypes: {
        resolversMap: {
            name: string;
        };
        userDefined: Record<string, {
            name: string;
            hasIsTypeOf: boolean;
            federation?: {
                hasResolveReference: boolean;
            };
        }>;
    };
}
export interface RawResolversConfig extends RawConfig {
    /**
     * @description Adds `_` to generated `Args` types in order to avoid duplicate identifiers.
     *
     * @exampleMarkdown
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          addUnderscoreToArgsType: true
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     */
    addUnderscoreToArgsType?: boolean;
    /**
     * @description Use this configuration to set a custom type for your `context`, and it will
     * affect all the resolvers, without the need to override it using generics each time.
     * If you wish to use an external type and import it from another file, you can use `add` plugin
     * and add the required `import` statement, or you can use a `module#type` syntax.
     *
     * @exampleMarkdown
     * ## Custom Context Type
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          contextType: 'MyContext'
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     * ## Custom Context Type by Path
     *
     * Note that the path should be relative to the generated file.
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          contextType: './my-types#MyContext'
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    contextType?: string;
    /**
     * @description Use this to set a custom type for a specific field `context`.
     * It will only affect the targeted resolvers.
     * You can either use `Field.Path#ContextTypeName` or `Field.Path#ExternalFileName#ContextTypeName`
     *
     * @exampleMarkdown
     * ## Custom Field Context Types
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          fieldContextTypes: ['MyType.foo#CustomContextType', 'MyType.bar#./my-file#ContextTypeOne']
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     */
    fieldContextTypes?: Array<string>;
    /**
     * @description Use this configuration to set a custom type for the `rootValue`, and it will
     * affect resolvers of all root types (Query, Mutation and Subscription), without the need to override it using generics each time.
     * If you wish to use an external type and import it from another file, you can use `add` plugin
     * and add the required `import` statement, or you can use both `module#type` or `module#namespace#type` syntax.
     *
     * @exampleMarkdown
     * ## Custom RootValue Type
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          rootValueType: 'MyRootValue'
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     * ## Custom RootValue Type
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          rootValueType: './my-types#MyRootValue'
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    rootValueType?: string;
    /**
     * @description Use this to set a custom type for a specific field `context` decorated by a directive.
     * It will only affect the targeted resolvers.
     * You can either use `Field.Path#ContextTypeName` or `Field.Path#ExternalFileName#ContextTypeName`
     *
     * ContextTypeName should by a generic Type that take the context or field context type as only type parameter.
     *
     * @exampleMarkdown
     * ## Directive Context Extender
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          directiveContextTypes: ['myCustomDirectiveName#./my-file#CustomContextExtender']
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     */
    directiveContextTypes?: Array<string>;
    /**
     * @description Adds a suffix to the imported names to prevent name clashes.
     *
     * @exampleMarkdown
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          mapperTypeSuffix: 'Model'
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    mapperTypeSuffix?: string;
    /**
     * @description Replaces a GraphQL type usage with a custom type, allowing you to return custom object from
     * your resolvers.
     * You can use both `module#type` and `module#namespace#type` syntax.
     *
     * @exampleMarkdown
     * ## Custom Context Type
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          mappers: {
     *            User: './my-models#UserDbObject',
     *            Book: './my-models#Collections',
     *          }
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    mappers?: {
        [typeName: string]: string;
    };
    /**
     * @description Allow you to set the default mapper when it's not being override by `mappers` or generics.
     * You can specify a type name, or specify a string in `module#type` or `module#namespace#type` format.
     * The default value of mappers is the TypeScript type generated by `typescript` package.
     *
     * @exampleMarkdown
     * ## Replace with any
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          defaultMapper: 'any',
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     * ## Custom Base Object
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          defaultMapper: './my-file#BaseObject',
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     * ## Wrap default types with Partial
     *
     * You can also specify a custom wrapper for the original type, without overriding the original generated types, use `{T}` to specify the identifier. (for flow, use `$Shape<{T}>`)
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        // plugins...
     *        config: {
     *          defaultMapper: 'Partial<{T}>',
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     * ## Allow deep partial with `utility-types`
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        plugins: ['typescript', 'typescript-resolver', { add: { content: "import { DeepPartial } from 'utility-types';" } }],
     *        config: {
     *          defaultMapper: 'DeepPartial<{T}>',
     *          avoidCheckingAbstractTypesRecursively: true // required if you have complex nested abstract types
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    defaultMapper?: string;
    /**
     * @description This will cause the generator to avoid using optionals (`?`),
     * so all field resolvers must be implemented in order to avoid compilation errors.
     * @default false
     *
     * @exampleMarkdown
     * ## Override all definition types
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        plugins: ['typescript', 'typescript-resolver'],
     *        config: {
     *          avoidOptionals: true
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     * ## Override only specific definition types
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        plugins: ['typescript', 'typescript-resolver'],
     *        config: {
     *          avoidOptionals: {
     *            field: true,
     *            inputValue: true,
     *            object: true,
     *            defaultValue: true,
     *            query: true,
     *            mutation: true,
     *            subscription: true,
     *          }
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    avoidOptionals?: boolean | AvoidOptionalsConfig;
    /**
     * @description Warns about unused mappers.
     * @default true
     *
     * @exampleMarkdown
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        plugins: ['typescript', 'typescript-resolver'],
     *        config: {
     *          showUnusedMappers: true,
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    showUnusedMappers?: boolean;
    /**
     * @description Overrides the default value of enum values declared in your GraphQL schema, supported
     * in this plugin because of the need for integration with `typescript` package.
     * See documentation under `typescript` plugin for more information and examples.
     */
    enumValues?: EnumValuesMap;
    /**
     * @default Promise<T> | T
     * @description Allow you to override `resolverTypeWrapper` definition.
     */
    resolverTypeWrapperSignature?: string;
    /**
     * @default false
     * @description Supports Apollo Federation
     */
    federation?: boolean;
    /**
     * @default true
     * @description Allow you to disable prefixing for generated enums, works in combination with `typesPrefix`.
     *
     * @exampleMarkdown
     * ## Disable enum prefixes
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        plugins: ['typescript', 'typescript-resolver'],
     *        config: {
     *          typesPrefix: 'I',
     *          enumPrefix: false
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    enumPrefix?: boolean;
    /**
     * @default true
     * @description Allow you to disable suffixing for generated enums, works in combination with `typesSuffix`.
     *
     * @exampleMarkdown
     * ## Disable enum suffixes
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        plugins: ['typescript', 'typescript-resolver'],
     *        config: {
     *          typesSuffix: 'I',
     *          enumSuffix: false
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    enumSuffix?: boolean;
    /**
     * @description Configures behavior for custom directives from various GraphQL libraries.
     * @exampleMarkdown
     * ## `@semanticNonNull`
     * First, install `graphql-sock` peer dependency:
     *
     * ```sh npm2yarn
     * npm install -D graphql-sock
     * ```
     *
     * Now, you can enable support for `@semanticNonNull` directive:
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file.ts': {
     *        plugins: ['typescript-resolvers'],
     *        config: {
     *          customDirectives: {
     *            semanticNonNull: true
     *          }
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    customDirectives?: {
        semanticNonNull?: boolean;
    };
    /**
     * @default false
     * @description Sets the `__resolveType` field as optional field.
     */
    optionalResolveType?: boolean;
    /**
     * @default false
     * @description Generates immutable types by adding `readonly` to properties and uses `ReadonlyArray`.
     */
    immutableTypes?: boolean;
    /**
     * @default ''
     * @description Prefixes all GraphQL related generated types with that value, as namespaces import.
     * You can use this feature to allow separation of plugins to different files.
     */
    namespacedImportName?: string;
    /**
     * @default Resolvers
     * @description Suffix we add to each generated type resolver.
     */
    resolverTypeSuffix?: string;
    /**
     * @default Resolvers
     * @description The type name to use when exporting all resolvers signature as unified type.
     */
    allResolversTypeName?: string;
    /**
     * @type string
     * @default '__'
     * @description Defines the prefix value used for `__resolveType` and `__isTypeOf` resolvers.
     * If you are using `mercurius-js`, please set this field to empty string for better compatibility.
     */
    internalResolversPrefix?: string;
    /**
     * @description Makes `__typename` of resolver mappings non-optional without affecting the base types.
     * @default false
     *
     * @exampleMarkdown
     * ## Enable for all
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        plugins: ['typescript', 'typescript-resolver'],
     *        config: {
     *          resolversNonOptionalTypename: true // or { unionMember: true, interfaceImplementingType: true }
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     * ## Enable except for some types
     *
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file': {
     *        plugins: ['typescript', 'typescript-resolver'],
     *        config: {
     *          resolversNonOptionalTypename: {
     *            unionMember: true,
     *            interfaceImplementingType: true,
     *            excludeTypes: ['MyType'],
     *          }
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    resolversNonOptionalTypename?: boolean | ResolversNonOptionalTypenameConfig;
    /**
     * @type boolean
     * @default false
     * @description If true, recursively goes through all object type's fields, checks if they have abstract types and generates expected types correctly.
     * This may not work for cases where provided default mapper types are also nested e.g. `defaultMapper: DeepPartial<{T}>` or `defaultMapper: Partial<{T}>`.
     */
    avoidCheckingAbstractTypesRecursively?: boolean;
    /**
     * @description If true, add field resolver types to Interfaces.
     * By default, GraphQL Interfaces do not trigger any field resolvers,
     * meaning every implementing type must implement the same resolver for the shared fields.
     *
     * Some tools provide a way to change the default behaviour by making GraphQL Objects inherit
     * missing resolvers from their Interface types. In these cases, it is fine to turn this option to true.
     *
     * For example, if you are using `@graphql-tools/schema#makeExecutableSchema` with `inheritResolversFromInterfaces: true`,
     * you can make `addInterfaceFieldResolverTypes: true` as well
     * https://the-guild.dev/graphql/tools/docs/generate-schema#makeexecutableschema
     *
     * @exampleMarkdown
     * ```ts filename="codegen.ts"
     * import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     * const config: CodegenConfig = {
     *   // ...
     *   generates: {
     *     'path/to/file': {
     *       plugins: ['typescript', 'typescript-resolver'],
     *       config: {
     *         addInterfaceFieldResolverTypes: true,
     *       },
     *     },
     *   },
     * };
     * export default config;
     * ```
     *
     * @type boolean
     * @default false
     */
    addInterfaceFieldResolverTypes?: boolean;
    /**
     * @ignore
     */
    directiveResolverMappings?: Record<string, string>;
}
export type ResolverTypes = {
    [gqlType: string]: string;
};
export type ResolverParentTypes = {
    [gqlType: string]: string;
};
export type GroupedMappers = Record<string, {
    identifier: string;
    asDefault?: boolean;
}[]>;
type FieldContextTypeMap = Record<string, ParsedMapper>;
export declare class BaseResolversVisitor<TRawConfig extends RawResolversConfig = RawResolversConfig, TPluginConfig extends ParsedResolversConfig = ParsedResolversConfig> extends BaseVisitor<TRawConfig, TPluginConfig> {
    private _schema;
    protected _parsedConfig: TPluginConfig;
    protected _declarationBlockConfig: DeclarationBlockConfig;
    protected _collectedResolvers: {
        [key: string]: {
            typename: string;
            baseGeneratedTypename?: string;
        };
    };
    protected _parsedSchemaMeta: {
        types: {
            interface: Record<string, {
                type: GraphQLInterfaceType;
                implementingTypes: Record<string, GraphQLObjectType>;
            }>;
            union: Record<string, {
                type: GraphQLUnionType;
                unionMembers: Record<string, GraphQLObjectType>;
            }>;
        };
        typesWithIsTypeOf: Record<string, true>;
    };
    protected _collectedDirectiveResolvers: {
        [key: string]: string;
    };
    protected _variablesTransformer: OperationVariablesToObject;
    protected _usedMappers: {
        [key: string]: boolean;
    };
    protected _resolversTypes: ResolverTypes;
    protected _resolversParentTypes: ResolverParentTypes;
    protected _hasReferencedResolversUnionTypes: boolean;
    protected _hasReferencedResolversInterfaceTypes: boolean;
    protected _resolversUnionTypes: Record<string, string>;
    protected _resolversInterfaceTypes: Record<string, string>;
    protected _rootTypeNames: Set<string>;
    protected _globalDeclarations: Set<string>;
    protected _federation: ApolloFederation;
    protected _hasScalars: boolean;
    protected _fieldContextTypeMap: FieldContextTypeMap;
    protected _directiveContextTypesMap: FieldContextTypeMap;
    protected _checkedTypesWithNestedAbstractTypes: Record<string, {
        checkStatus: 'yes' | 'no' | 'checking';
    }>;
    private _directiveResolverMappings;
    private _shouldMapType;
    constructor(rawConfig: TRawConfig, additionalConfig: TPluginConfig, _schema: GraphQLSchema, defaultScalars?: NormalizedScalarsMap, federationMeta?: FederationMeta);
    getResolverTypeWrapperSignature(): string;
    protected shouldMapType(type: GraphQLNamedType, duringCheck?: string[]): boolean;
    convertName(node: ASTNode | string, options?: BaseVisitorConvertOptions & ConvertOptions, applyNamespacedImport?: boolean): string;
    protected createResolversFields({ applyWrapper, clearWrapper, getTypeToUse, currentType, shouldInclude, onNotMappedObjectType, }: {
        applyWrapper: (str: string) => string;
        clearWrapper: (str: string) => string;
        getTypeToUse: (str: string) => string;
        currentType: 'ResolversTypes' | 'ResolversParentTypes';
        shouldInclude?: (type: GraphQLNamedType) => boolean;
        onNotMappedObjectType: (params: {
            initialType: string;
            typeName: string;
        }) => string;
    }): ResolverTypes;
    protected replaceFieldsInType(typeName: string, relevantFields: ReturnType<typeof this.getRelevantFieldsToOmit>): string;
    protected applyMaybe(str: string): string;
    protected applyResolverTypeWrapper(str: string): string;
    protected clearMaybe(str: string): string;
    protected clearResolverTypeWrapper(str: string): string;
    protected wrapWithArray(t: string): string;
    protected createResolversUnionTypes(): Record<string, string>;
    protected createResolversInterfaceTypes(): Record<string, string>;
    /**
     * Function to generate the types of Abstract Type Members i.e. Union Members or Interface Implementing Types
     */
    getAbstractMembersType({ typeName, memberTypes, isTypenameNonOptional, }: {
        typeName: string;
        memberTypes: readonly GraphQLObjectType[] | GraphQLObjectType[];
        isTypenameNonOptional: boolean;
    }): string;
    protected createFieldContextTypeMap(): FieldContextTypeMap;
    protected createDirectivedContextType(): FieldContextTypeMap;
    buildResolversTypes(): string;
    buildResolversParentTypes(): string;
    buildResolversUnionTypes(): string;
    buildResolversInterfaceTypes(): string;
    buildFederationTypes(): string;
    buildFederationReferenceTypes(): string;
    get schema(): GraphQLSchema;
    get defaultMapperType(): string;
    get unusedMappers(): string[];
    get globalDeclarations(): string[];
    protected isMapperImported(groupedMappers: GroupedMappers, identifier: string, source: string): boolean;
    get mappersImports(): string[];
    setDeclarationBlockConfig(config: DeclarationBlockConfig): void;
    setVariablesTransformer(variablesTransfomer: OperationVariablesToObject): void;
    hasScalars(): boolean;
    hasFederation(): boolean;
    getRootResolver(): RootResolver;
    protected formatRootResolver(schemaTypeName: string, resolverType: string, declarationKind: DeclarationKind): string;
    getAllDirectiveResolvers(): string;
    ListType(node: ListTypeNode): string;
    protected _getScalar(name: string): string;
    NamedType(node: NamedTypeNode): string;
    NonNullType(node: NonNullTypeNode): string;
    protected markMapperAsUsed(name: string): void;
    protected getTypeToUse(name: string): string;
    protected getParentTypeToUse(name: string): string;
    protected getParentTypeForSignature(_node: FieldDefinitionNode): string;
    protected transformParentGenericType(parentType: string): string;
    FieldDefinition(node: FieldDefinitionNode, key: string | number, parent: any): FieldDefinitionResult;
    private getFieldContextType;
    private getContextType;
    private parseSchemaMeta;
    protected applyRequireFields(argsType: string, fields: InputValueDefinitionNode[]): string;
    protected applyOptionalFields(argsType: string, _fields: readonly InputValueDefinitionNode[]): string;
    ObjectTypeDefinition(node: ObjectTypeDefinitionNode): string | null;
    UnionTypeDefinition(node: UnionTypeDefinitionNode, key: string | number, parent: any): string;
    ScalarTypeDefinition(node: ScalarTypeDefinitionNode): string;
    DirectiveDefinition(node: DirectiveDefinitionNode, key: string | number, parent: any): string;
    protected buildEnumResolverContentBlock(_node: EnumTypeDefinitionNode, _mappedEnumType: string): string;
    protected buildEnumResolversExplicitMappedValues(_node: EnumTypeDefinitionNode, _valuesMapping: {
        [valueName: string]: string | number;
    }): string;
    EnumTypeDefinition(node: EnumTypeDefinitionNode): string;
    InterfaceTypeDefinition(node: InterfaceTypeDefinitionNode): string;
    SchemaDefinition(): any;
    SchemaExtension(): any;
    private getRelevantFieldsToOmit;
}
export {};
