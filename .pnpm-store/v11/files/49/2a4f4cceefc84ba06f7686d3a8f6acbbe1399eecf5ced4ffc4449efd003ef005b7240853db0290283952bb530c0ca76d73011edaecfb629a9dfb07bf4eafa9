import { DocumentNode, GraphQLSchema, ParseOptions } from 'graphql';
import { SchemaPrintOptions } from '@graphql-tools/utils';
export type OptimizeDocumentsOptions = SchemaPrintOptions & ParseOptions & {
    includeFragments?: boolean;
};
export declare function optimizeDocuments(schema: GraphQLSchema, documents: DocumentNode[], options?: OptimizeDocumentsOptions): DocumentNode[];
