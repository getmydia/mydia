import { FragmentDefinitionNode, OperationDefinitionNode } from 'graphql';
import { SourceWithOperations } from '@graphql-codegen/gql-tag-operations';
import type { Types } from '@graphql-codegen/plugin-helpers';
export type BuildNameFunction = (type: OperationDefinitionNode | FragmentDefinitionNode) => string;
export declare function processSources(sources: Array<Types.DocumentFile>, buildName: BuildNameFunction): Array<SourceWithOperations>;
