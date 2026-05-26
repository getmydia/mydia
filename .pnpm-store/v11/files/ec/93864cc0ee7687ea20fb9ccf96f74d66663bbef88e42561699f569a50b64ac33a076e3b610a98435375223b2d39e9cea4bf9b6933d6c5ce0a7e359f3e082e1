import { FragmentDefinitionNode, GraphQLSchema, OperationDefinitionNode } from 'graphql';
import { BaseVisitor, type ParsedConfig, type RawConfig } from './base-visitor.js';
import { NormalizedOperationAvoidOptionalsConfig, type OperationAvoidOptionalsConfig } from './operation-avoid-optionals.js';
import { type NormalizedOperationDeclarationKindConfig, type OperationDeclarationKind, type OperationDeclarationKindConfig } from './operation-declaration-kinds.js';
import { SelectionSetToObject } from './selection-set-to-object.js';
import { CustomDirectivesConfig, NormalizedScalarsMap } from './types.js';
import { DeclarationBlockConfig } from './utils.js';
import { OperationVariablesToObject } from './variables-to-object.js';
export interface ParsedDocumentsConfig extends ParsedConfig {
    extractAllFieldsToTypes: boolean;
    extractAllFieldsToTypesCompact: boolean;
    operationResultSuffix: string;
    dedupeOperationSuffix: boolean;
    omitOperationSuffix: boolean;
    exportFragmentSpreadSubTypes: boolean;
    skipTypeNameForRoot: boolean;
    nonOptionalTypename: boolean;
    globalNamespace: boolean;
    experimentalFragmentVariables: boolean;
    mergeFragmentTypes: boolean;
    customDirectives: CustomDirectivesConfig;
    generateOperationTypes: boolean;
    importSchemaTypesFrom: string;
    namespacedImportName: string | null;
    declarationKind: NormalizedOperationDeclarationKindConfig;
    avoidOptionals: NormalizedOperationAvoidOptionalsConfig;
}
export interface RawDocumentsConfig extends RawConfig {
    /**
     * @description This will cause the generator to avoid using TypeScript optionals (`?`) on types,
     * so the following definition: `type A { myField: String }` will output `myField: Maybe<string>`
     * instead of `myField?: Maybe<string>`.
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
     *      'path/to/file.ts': {
     *        plugins: ['typescript-operations'],
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
     *      'path/to/file.ts': {
     *        plugins: ['typescript-operations'],
     *        config: {
     *          avoidOptionals: {
     *            variableValue: true,
     *            inputValue: true,
     *            defaultValue: true,
     *          }
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    avoidOptionals?: boolean | OperationAvoidOptionalsConfig;
    /**
     * @default false
     * @description Avoid adding `__typename` for root types. This is ignored when a selection explicitly specifies `__typename`.
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
     *          skipTypeNameForRoot: true
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    skipTypeNameForRoot?: boolean;
    /**
     * @default false
     * @description Automatically adds `__typename` field to the generated types, even when they are not specified
     * in the selection set, and makes it non-optional
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
     *          nonOptionalTypename: true
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    nonOptionalTypename?: boolean;
    /**
     * @default false
     * @description Puts all generated code under `global` namespace. Useful for Stencil integration.
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
     *          globalNamespace: true
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    globalNamespace?: boolean;
    /**
     * @default ""
     * @description Adds a suffix to generated operation result type names
     */
    operationResultSuffix?: string;
    /**
     * @default false
     * @description Set this configuration to `true` if you wish to make sure to remove duplicate operation name suffix.
     */
    dedupeOperationSuffix?: boolean;
    /**
     * @default false
     * @description Set this configuration to `true` if you wish to disable auto add suffix of operation name, like `Query`, `Mutation`, `Subscription`, `Fragment`.
     */
    omitOperationSuffix?: boolean;
    /**
     * @default false
     * @description If set to true, it will export the sub-types created in order to make it easier to access fields declared under fragment spread.
     */
    exportFragmentSpreadSubTypes?: boolean;
    /**
     * @default false
     * @description If set to true, it will enable support for parsing variables on fragments.
     */
    experimentalFragmentVariables?: boolean;
    /**
     * @default false
     * @description If set to true, merge equal fragment interfaces.
     */
    mergeFragmentTypes?: boolean;
    /**
     * @description Prefixes all GraphQL related generated types with that value, as namespaces import.
     * You can use this feature to allow separation of plugins to different files (See `importSchemaTypesFrom`)
     * @default 'Types' (if `importSchemaTypesFrom` is set)
     * @exampleMarkdown
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file.ts': {
     *        plugins: ['typescript-operations'],
     *        config: {
     *          importSchemaTypesFrom: './path/to/shared-types.ts',
     *          namespacedImportName: 'Types'
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    namespacedImportName?: string;
    /**
     * @description Configures behavior for use with custom directives from
     * various GraphQL libraries.
     * @exampleMarkdown
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file.ts': {
     *        plugins: ['typescript'],
     *        config: {
     *          customDirectives: {
     *            apolloUnmask: true
     *          }
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    customDirectives?: CustomDirectivesConfig;
    /**
     * @description Whether to generate operation types such as Variables, Query/Mutation/Subscription selection set, and Fragment types
     * This can be used with `importSchemaTypesFrom` to generate shared used Enums and Input.
     * @default true
     * @exampleMarkdown
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file.ts': {
     *        plugins: ['typescript-operations'],
     *        config: {
     *          generateOperationTypes: false,
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    generateOperationTypes?: boolean;
    /**
     * @description The absolute (prefixed with `~`) or relative path from `cwd` to the shared used Enums and Input (See `generateOperationTypes`).
     * @default true
     * @exampleMarkdown
     * ```ts filename="codegen.ts"
     *  import type { CodegenConfig } from '@graphql-codegen/cli';
     *
     *  const config: CodegenConfig = {
     *    // ...
     *    generates: {
     *      'path/to/file.ts': {
     *        plugins: ['typescript-operations'],
     *        config: {
     *          importSchemaTypesFrom: './path/to/shared-types.ts', // relative
     *          importSchemaTypesFrom: '~@my-org/package' // absolute
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    importSchemaTypesFrom?: string;
    /**
     * @default false
     * @description Extract all field types to their own types, instead of inlining them.
     * This helps to reduce type duplication, and makes type errors more readable.
     * It can also significantly reduce the size of the generated code, the generation time,
     * and the typechecking time.
     */
    extractAllFieldsToTypes?: boolean;
    /**
     * @default false
     * @description Generates type names using only field names, omitting GraphQL type names.
     * This matches the naming convention used by Apollo Tooling.
     * For example, instead of `Query_company_Company_office_Office_location_Location`,
     * it generates `Query_company_office_location`.
     *
     * When this option is enabled, `extractAllFieldsToTypes` is automatically enabled as well.
     */
    extractAllFieldsToTypesCompact?: boolean;
    /**
     * @description Overrides the default output for various GraphQL types.
     * @default 'type'
     * @exampleMarkdown
     * ## Override all declarations
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
     *          declarationKind: 'interface'
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     *
     * ## Override only specific declarations
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
     *          declarationKind: {
     *            input: 'interface',
     *            result: 'type'
     *          }
     *        },
     *      },
     *    },
     *  };
     *  export default config;
     * ```
     */
    declarationKind?: OperationDeclarationKind | OperationDeclarationKindConfig;
}
export declare class BaseDocumentsVisitor<TRawConfig extends RawDocumentsConfig = RawDocumentsConfig, TPluginConfig extends ParsedDocumentsConfig = ParsedDocumentsConfig> extends BaseVisitor<TRawConfig, TPluginConfig> {
    protected _schema: GraphQLSchema;
    protected _unnamedCounter: number;
    protected _variablesTransfomer: OperationVariablesToObject;
    protected _selectionSetToObject: SelectionSetToObject;
    protected _globalDeclarations: Set<string>;
    constructor(rawConfig: TRawConfig, additionalConfig: TPluginConfig, _schema: GraphQLSchema, defaultScalars?: NormalizedScalarsMap);
    getGlobalDeclarations(noExport?: boolean): string[];
    setSelectionSetHandler(handler: SelectionSetToObject): void;
    setDeclarationBlockConfig(config: DeclarationBlockConfig): void;
    setVariablesTransformer(variablesTransfomer: OperationVariablesToObject): void;
    get schema(): GraphQLSchema;
    private handleAnonymousOperation;
    FragmentDefinition(node: FragmentDefinitionNode): string;
    protected applyVariablesWrapper(variablesBlock: string, _operationType?: string): string;
    OperationDefinition(node: OperationDefinitionNode): string | null;
}
