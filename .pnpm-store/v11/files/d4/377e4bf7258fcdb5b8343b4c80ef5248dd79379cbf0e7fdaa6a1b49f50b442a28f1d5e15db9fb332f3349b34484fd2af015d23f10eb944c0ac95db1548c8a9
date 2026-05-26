import { GraphQLSchema } from 'graphql';
import type { Source } from 'graphql-config';
import { Types } from '@graphql-codegen/plugin-helpers';
import { UnnormalizedTypeDefPointer } from '@graphql-tools/load';
export declare const defaultSchemaLoadOptions: {
    assumeValidSDL: boolean;
    sort: boolean;
    convertExtensions: boolean;
    includeSources: boolean;
};
export declare const defaultDocumentsLoadOptions: {
    sort: boolean;
    skipGraphQLImport: boolean;
};
export declare function loadSchema(schemaPointers: UnnormalizedTypeDefPointer | UnnormalizedTypeDefPointer[], config: Types.Config): Promise<GraphQLSchema>;
export declare function loadDocuments(documentPointers: UnnormalizedTypeDefPointer | UnnormalizedTypeDefPointer[], config: Types.Config): Promise<Source[]>;
