import { GraphQLInterfaceType, GraphQLObjectType } from 'graphql';
import { BaseSelectionSetProcessor, LinkField, PrimitiveAliasedFields, PrimitiveField, ProcessResult, SelectionSetProcessorConfig } from './base.cjs';
export declare class PreResolveTypesProcessor extends BaseSelectionSetProcessor<SelectionSetProcessorConfig> {
    transformTypenameField(type: string, name: string): ProcessResult;
    transformPrimitiveFields(schemaType: GraphQLObjectType | GraphQLInterfaceType, fields: PrimitiveField[], unsetTypes?: boolean): ProcessResult;
    transformAliasesPrimitiveFields(schemaType: GraphQLObjectType | GraphQLInterfaceType, fields: PrimitiveAliasedFields[], unsetTypes?: boolean): ProcessResult;
    transformLinkFields(fields: LinkField[], unsetTypes?: boolean): ProcessResult;
}
