import { GraphQLInterfaceType, GraphQLObjectType } from 'graphql';
import { BaseSelectionSetProcessor, LinkField, PrimitiveAliasedFields, PrimitiveField, ProcessResult, SelectionSetProcessorConfig } from '@graphql-codegen/visitor-plugin-common';
export declare class TypeScriptSelectionSetProcessor extends BaseSelectionSetProcessor<SelectionSetProcessorConfig> {
    transformPrimitiveFields(schemaType: GraphQLObjectType | GraphQLInterfaceType, fields: PrimitiveField[], unsetTypes?: boolean): ProcessResult;
    transformTypenameField(type: string, name: string): ProcessResult;
    transformAliasesPrimitiveFields(schemaType: GraphQLObjectType | GraphQLInterfaceType, fields: PrimitiveAliasedFields[]): ProcessResult;
    transformLinkFields(fields: LinkField[]): ProcessResult;
}
