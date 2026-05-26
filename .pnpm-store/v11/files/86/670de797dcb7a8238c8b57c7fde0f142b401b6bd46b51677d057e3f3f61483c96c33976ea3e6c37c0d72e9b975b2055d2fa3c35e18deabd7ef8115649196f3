import { FragmentDefinitionNode, OperationDefinitionNode } from 'graphql';
import { PluginFunction } from '@graphql-codegen/plugin-helpers';
import type { Types } from '@graphql-codegen/plugin-helpers';
import { DocumentMode } from '@graphql-codegen/visitor-plugin-common';
export type OperationOrFragment = {
    initialName: string;
    definition: OperationDefinitionNode | FragmentDefinitionNode;
};
export type SourceWithOperations = {
    source: Types.DocumentFile;
    operations: Array<OperationOrFragment>;
};
export declare const plugin: PluginFunction<{
    sourcesWithOperations: Array<SourceWithOperations>;
    useTypeImports?: boolean;
    augmentedModuleName?: string;
    gqlTagName?: string;
    emitLegacyCommonJSImports?: boolean;
    importExtension?: '' | `.${string}`;
    documentMode?: DocumentMode;
}>;
