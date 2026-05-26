import { DirectiveNode, FieldNode, FragmentSpreadNode, GraphQLNamedType, GraphQLObjectType, GraphQLSchema, InlineFragmentNode, SelectionNode, SelectionSetNode } from 'graphql';
import { ParsedDocumentsConfig } from './base-documents-visitor.js';
import { BaseVisitorConvertOptions } from './base-visitor.js';
import { BaseSelectionSetProcessor, LinkField, NameAndType, PrimitiveAliasedFields, PrimitiveField } from './selection-set-processor/base.js';
import { ConvertNameFn, FragmentDirectives, GetFragmentSuffixFn, LoadedFragment, NormalizedScalarsMap } from './types.js';
import { DeclarationBlockConfig } from './utils.js';
type FragmentSpreadUsage = {
    fragmentName: string;
    typeName: string;
    onType: string;
    selectionNodes: Array<SelectionNode>;
    fragmentDirectives?: DirectiveNode[];
};
interface DependentType {
    name: string;
    content: string;
    isUnionType?: boolean;
}
type CollectedFragmentNode = (SelectionNode | FragmentSpreadUsage | DirectiveNode) & FragmentDirectives;
type GroupedStringifiedTypes = Record<string, Array<string | {
    union: string[];
}>>;
export declare class SelectionSetToObject<Config extends ParsedDocumentsConfig = ParsedDocumentsConfig> {
    protected _processor: BaseSelectionSetProcessor<any>;
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
    constructor(_processor: BaseSelectionSetProcessor<any>, _scalars: NormalizedScalarsMap, _schema: GraphQLSchema, _convertName: ConvertNameFn<BaseVisitorConvertOptions>, _getFragmentSuffix: GetFragmentSuffixFn, _loadedFragments: LoadedFragment[], _config: Config, _parentSchemaType?: GraphQLNamedType, _selectionSet?: SelectionSetNode);
    createNext(parentSchemaType: GraphQLNamedType, selectionSet: SelectionSetNode): SelectionSetToObject;
    /**
     * traverse the inline fragment nodes recursively for collecting the selectionSets on each type
     */
    _collectInlineFragments(parentType: GraphQLNamedType, nodes: Array<InlineFragmentNode & FragmentDirectives>, types: Map<string, Array<CollectedFragmentNode>>): any;
    protected _createInlineFragmentForFieldNodes(parentType: GraphQLNamedType, fieldNodes: FieldNode[]): InlineFragmentNode;
    /**
     * The `buildFragmentSpreadsUsage` method is used to collect fields from fragment spreads in the selection set.
     * It creates a record of fragment spread usages, which includes the fragment name, type name, and the selection nodes
     * inside the fragment.
     */
    protected buildFragmentSpreadsUsage(spreads: FragmentSpreadNode[]): Record<string, FragmentSpreadUsage[]>;
    protected flattenSelectionSet(selections: ReadonlyArray<SelectionNode>, parentSchemaType?: GraphQLObjectType<any, any>): Map<string, Array<SelectionNode | FragmentSpreadUsage>>;
    private _appendToTypeMap;
    protected _buildGroupedSelections(parentName: string): {
        grouped: GroupedStringifiedTypes;
        dependentTypes: DependentType[];
        mustAddEmptyObject: boolean;
    };
    protected selectionSetStringFromFields(fields: (string | NameAndType)[]): string | null;
    protected buildSelectionSet(parentSchemaType: GraphQLObjectType, selectionNodes: Array<SelectionNode | FragmentSpreadUsage | DirectiveNode>, options: {
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
    protected buildTypeNameField(type: GraphQLObjectType, nonOptionalTypename?: boolean, addTypename?: boolean, queriedForTypename?: boolean, skipTypeNameForRoot?: boolean): {
        name: string;
        type: string;
    };
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
