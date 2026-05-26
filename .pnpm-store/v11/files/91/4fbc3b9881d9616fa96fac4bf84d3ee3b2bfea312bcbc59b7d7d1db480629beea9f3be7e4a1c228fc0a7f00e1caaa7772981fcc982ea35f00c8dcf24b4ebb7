import { EnumTypeDefinitionNode, GraphQLEnumType, GraphQLInputObjectType, GraphQLScalarType, InputObjectTypeDefinitionNode, InputValueDefinitionNode, type DocumentNode, type GraphQLSchema, type TypeDefinitionNode } from 'graphql';
import { BaseDocumentsVisitor, DeclarationKind, ParsedDocumentsConfig, type ConvertSchemaEnumToDeclarationBlockString, type ParsedEnumValuesMap } from '@graphql-codegen/visitor-plugin-common';
import type { TypeScriptDocumentsPluginConfig } from './config.js';
export interface TypeScriptDocumentsParsedConfig extends ParsedDocumentsConfig {
    arrayInputCoercion: boolean;
    immutableTypes: boolean;
    noExport: boolean;
    maybeValue: string;
    inputMaybeValue: string;
    allowUndefinedQueryVariables: boolean;
    enumType: ConvertSchemaEnumToDeclarationBlockString['outputType'];
    enumValues: ParsedEnumValuesMap;
    ignoreEnumValuesFromSchema: boolean;
    futureProofEnums: boolean;
}
type UsedSchemaTypes = Record<string, {
    type: 'GraphQLScalarType';
    node: GraphQLScalarType;
    tsType: string;
    useCases: {
        input: boolean;
        output: boolean;
        variables: boolean;
    };
} | {
    type: 'GraphQLEnumType';
    node: GraphQLEnumType;
    tsType: string;
} | {
    type: 'GraphQLInputObjectType';
    node: GraphQLInputObjectType;
    tsType: string;
}>;
export declare class TypeScriptDocumentsVisitor extends BaseDocumentsVisitor<TypeScriptDocumentsPluginConfig, TypeScriptDocumentsParsedConfig> {
    protected _usedSchemaTypes: UsedSchemaTypes;
    protected _needsExactUtilityType: boolean;
    private _outputPath;
    constructor(schema: GraphQLSchema, config: TypeScriptDocumentsPluginConfig, documentNode: DocumentNode, outputPath: string);
    EnumTypeDefinition(node: EnumTypeDefinitionNode): string | null;
    InputObjectTypeDefinition(node: InputObjectTypeDefinitionNode): string | null;
    InputValueDefinition(node: InputValueDefinitionNode, _key?: number | string, _parent?: any, _path?: Array<string | number>, ancestors?: Array<TypeDefinitionNode>): string;
    getImports(): Array<string>;
    getExternalSchemaTypeImports(): Array<string>;
    getEnumsImports(): string[];
    getScalarsImports(): string[];
    protected getPunctuation(_declarationKind: DeclarationKind): string;
    protected applyVariablesWrapper(variablesBlock: string, operationType: string): string;
    private collectInnerTypesRecursively;
    /**
     * @description collects schema types used in operations:
     * - used Enums for Variables
     * - used Scalars for Variables
     * - used Input for Variables (recursively)
     *
     * - used Enums for Result
     * - used Scalars for Result
     */
    private collectUsedSchemaTypesToGenerate;
    getExactUtilityType(): string | null;
    getIncrementalUtilityType(): string | null;
}
export {};
