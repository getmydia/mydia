import { DirectiveNode, FieldNode, FragmentSpreadNode, GraphQLNamedType, GraphQLObjectType, GraphQLSchema, InlineFragmentNode, SelectionNode, SelectionSetNode } from 'graphql';
import { ParsedDocumentsConfig } from './base-documents-visitor.cjs';
import { BaseVisitorConvertOptions } from './base-visitor.cjs';
import { BaseSelectionSetProcessor, LinkField, NameAndType, PrimitiveAliasedFields, PrimitiveField, type SelectionSetProcessorConfig as BaseSelectionSetProcessorConfig } from './selection-set-processor/base.cjs';
import type { ConvertNameFn, GetFragmentSuffixFn, LoadedFragment, NormalizedScalarsMap } from './types.cjs';
import { DeclarationBlockConfig } from './utils.cjs';
type FragmentSpreadUsage = {
    fragmentName: string;
    typeName: string;
    onType: string;
    selectionNodes: Array<EnrichedFieldNode | FragmentSpreadNode | InlineFragmentNode>;
    fragmentDirectives: DirectiveNode[];
};
/**
 * @description EnrichedFieldNode are field nodes enriched with Codegen metadata for subsequent processing
 */
type EnrichedFieldNode = FieldNode & {
    /**
     * A field node may implicitly inherit fragment directives from parents
     * For example, if the field's parent is marked with `@skip`, the field is implicitly marked with `@skip` as well
     */
    fragmentDirectives?: DirectiveNode[];
};
interface DependentType {
    name: string;
    content: string;
    isUnionType?: boolean;
}
/**
 * Each grouped TypeName has an array of nodes.
 * These are collected when parsing the selection set,
 * then turned into TypeScript strings
 */
type GroupedTypeNameNode = EnrichedFieldNode | FragmentSpreadNode | InlineFragmentNode | FragmentSpreadUsage | DirectiveNode;
type GroupedStringifiedTypes = Record<string, Array<string | {
    union: string[];
}>>;
export declare class SelectionSetToObject<Config extends ParsedDocumentsConfig = ParsedDocumentsConfig, SelectionSetProcessorConfig extends BaseSelectionSetProcessorConfig = BaseSelectionSetProcessorConfig> {
    protected _processor: BaseSelectionSetProcessor<SelectionSetProcessorConfig>;
    protected _scalars: NormalizedScalarsMap;
    protected _schema: GraphQLSchema;
    protected _convertName: ConvertNameFn<BaseVisitorConvertOptions>;
    protected _getFragmentSuffix: GetFragmentSuffixFn;
    protected _loadedFragments: LoadedFragment[];
    protected _config: Config;
    protected _parentSchemaType?: GraphQLNamedType;
    protected _selectionSet?: SelectionSetNode;
    protected _primitiveFields: PrimitiveField[];
    protected _primitiveAliasedFields: PrimitiveAliasedFields[];
    protected _linksFields: LinkField[];
    protected _queriedForTypename: boolean;
    protected _seenFieldNames: Map<string, string>;
    constructor(_processor: BaseSelectionSetProcessor<SelectionSetProcessorConfig>, _scalars: NormalizedScalarsMap, _schema: GraphQLSchema, _convertName: ConvertNameFn<BaseVisitorConvertOptions>, _getFragmentSuffix: GetFragmentSuffixFn, _loadedFragments: LoadedFragment[], _config: Config, _parentSchemaType?: GraphQLNamedType, _selectionSet?: SelectionSetNode);
    createNext(parentSchemaType: GraphQLNamedType, selectionSet: SelectionSetNode): SelectionSetToObject;
    /**
     * traverse the inline fragment nodes recursively for collecting the selectionSets on each type
     */
    _collectInlineFragments(parentType: GraphQLNamedType, nodes: Array<InlineFragmentNode>, types: Map<string, Array<GroupedTypeNameNode>>): void;
    /**
     * The `buildFragmentSpreadsUsage` method is used to collect fields from fragment spreads in the selection set.
     * It creates a record of fragment spread usages, which includes the fragment name, type name, and the selection nodes
     * inside the fragment.
     */
    protected buildFragmentSpreadsUsage(spreads: FragmentSpreadNode[]): Record<string, FragmentSpreadUsage[]>;
    protected flattenSelectionSet(selections: ReadonlyArray<SelectionNode>, parentSchemaType?: GraphQLObjectType<any, any>): {
        selectionNodesByTypeName: Map<string, Array<GroupedTypeNameNode>>;
        selectionNodesByTypeNameConditional: Array<Map<string, Array<GroupedTypeNameNode>>>;
    };
    private _appendToTypeMap;
    protected _buildGroupedSelections(parentName: string): {
        grouped: GroupedStringifiedTypes;
        dependentTypes: DependentType[];
        mustAddEmptyObject: boolean;
    };
    protected selectionSetStringFromFields(fields: (string | NameAndType)[]): string | null;
    protected buildSelectionSet(parentSchemaType: GraphQLObjectType, selectionNodes: Array<GroupedTypeNameNode>, options: {
        unsetTypes?: boolean;
        parentFieldName?: string;
    }): {
        typeInfo: {
            name: string;
            type: string;
        };
        fields: string[];
        dependentTypes: DependentType[];
    };
    protected buildTypeNameField(type: GraphQLObjectType, nonOptionalTypename: boolean, queriedForTypename: boolean, skipTypeNameForRoot: boolean): {
        name: string;
        type: string;
    } | null;
    protected getUnknownType(): string;
    protected getEmptyObjectType(): string;
    private getEmptyObjectTypeString;
    transformSelectionSet(fieldName: string): {
        mergedTypeString: string;
        dependentTypes: DependentType[];
        isUnionType?: boolean;
    };
    private transformSelectionSetUncached;
    transformFragmentSelectionSetToTypes(fragmentName: string, fragmentSuffix: string, declarationBlockConfig: DeclarationBlockConfig): string;
    protected buildFragmentTypeName(name: string, suffix: string, typeName?: string): string;
    protected buildParentFieldName(typeName: string, parentName: string): string;
}
export {};
