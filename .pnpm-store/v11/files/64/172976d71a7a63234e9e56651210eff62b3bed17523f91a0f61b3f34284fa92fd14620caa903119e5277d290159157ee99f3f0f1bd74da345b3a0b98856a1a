import { GraphQLInterfaceType, GraphQLNamedType, GraphQLObjectType, GraphQLOutputType, Location } from 'graphql';
import { AvoidOptionalsConfig, ConvertNameFn, NormalizedScalarsMap } from '../types.js';
export type PrimitiveField = {
    isConditional: boolean;
    fieldName: string;
};
export type PrimitiveAliasedFields = {
    isConditional: boolean;
    alias: string;
    fieldName: string;
};
export type LinkField = {
    alias: string;
    name: string;
    type: string;
    selectionSet: string;
};
export type NameAndType = {
    name: string;
    type: string;
};
export type ProcessResult = null | Array<NameAndType | string>;
export type SelectionSetProcessorConfig = {
    namespacedImportName: string | null;
    convertName: ConvertNameFn<any>;
    enumPrefix: boolean | null;
    enumSuffix: boolean | null;
    scalars: NormalizedScalarsMap;
    formatNamedField(name: string, type?: GraphQLOutputType | GraphQLNamedType | null, isConditional?: boolean, isOptional?: boolean): string;
    wrapTypeWithModifiers(baseType: string, type: GraphQLOutputType | GraphQLNamedType): string;
    avoidOptionals?: AvoidOptionalsConfig | boolean;
    printFieldsOnNewLines?: boolean;
};
export declare class BaseSelectionSetProcessor<Config extends SelectionSetProcessorConfig> {
    config: Config;
    typeCache: Map<Location, Map<string, [string, string]>>;
    constructor(config: Config);
    buildFieldsIntoObject(allObjectsMerged: string[]): string;
    buildSelectionSetFromStrings(pieces: string[]): string;
    transformPrimitiveFields(_schemaType: GraphQLObjectType | GraphQLInterfaceType, _fields: PrimitiveField[], _unsetTypes?: boolean): ProcessResult;
    transformAliasesPrimitiveFields(_schemaType: GraphQLObjectType | GraphQLInterfaceType, _fields: PrimitiveAliasedFields[], _unsetTypes?: boolean): ProcessResult;
    transformLinkFields(_fields: LinkField[], _unsetTypes?: boolean): ProcessResult;
    transformTypenameField(_type: string, _name: string): ProcessResult;
}
