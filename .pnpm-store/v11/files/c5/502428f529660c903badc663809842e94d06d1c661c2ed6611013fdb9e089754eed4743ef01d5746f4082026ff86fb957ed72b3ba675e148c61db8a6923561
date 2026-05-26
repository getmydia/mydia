import { EnumTypeDefinitionNode, FieldDefinitionNode, GraphQLSchema, InputValueDefinitionNode, ListTypeNode, NamedTypeNode, NonNullTypeNode, TypeDefinitionNode, UnionTypeDefinitionNode } from 'graphql';
import { BaseTypesVisitor, DeclarationKind, NormalizedAvoidOptionalsConfig, ParsedTypesConfig } from '@graphql-codegen/visitor-plugin-common';
import { TypeScriptPluginConfig } from './config.cjs';
export interface TypeScriptPluginParsedConfig extends ParsedTypesConfig {
    avoidOptionals: NormalizedAvoidOptionalsConfig;
    constEnums: boolean;
    enumsAsTypes: boolean;
    futureProofEnums: boolean;
    futureProofUnions: boolean;
    enumsAsConst: boolean;
    numericEnums: boolean;
    onlyEnums: boolean;
    onlyOperationTypes: boolean;
    immutableTypes: boolean;
    maybeValue: string;
    inputMaybeValue: string;
    noExport: boolean;
    useImplementingTypes: boolean;
}
export declare class TsVisitor<TRawConfig extends TypeScriptPluginConfig = TypeScriptPluginConfig, TParsedConfig extends TypeScriptPluginParsedConfig = TypeScriptPluginParsedConfig> extends BaseTypesVisitor<TRawConfig, TParsedConfig> {
    constructor(schema: GraphQLSchema, pluginConfig: TRawConfig, additionalConfig?: Partial<TParsedConfig>);
    protected _getTypeForNode(node: NamedTypeNode, isVisitingInputType: boolean): string;
    getWrapperDefinitions(): string[];
    getMaybeValue(): string;
    getInputMaybeValue(): string;
    protected clearOptional(str: string): string;
    protected getExportPrefix(): string;
    getMaybeWrapper(ancestors: any): string;
    NamedType(node: NamedTypeNode, key: any, parent: any, path: any, ancestors: any): string;
    ListType(node: ListTypeNode, key: any, parent: any, path: any, ancestors: any): string;
    UnionTypeDefinition(node: UnionTypeDefinitionNode, key: string | number | undefined, parent: any): string;
    protected wrapWithListType(str: string): string;
    NonNullType(node: NonNullTypeNode): string;
    FieldDefinition(node: FieldDefinitionNode, key?: number | string, parent?: any): string;
    InputValueDefinition(node: InputValueDefinitionNode, key?: number | string, parent?: any, _path?: Array<string | number>, ancestors?: Array<TypeDefinitionNode>): string;
    EnumTypeDefinition(node: EnumTypeDefinitionNode): string;
    protected getPunctuation(_declarationKind: DeclarationKind): string;
}
