import { optimizeDocuments } from '@graphql-tools/relay-operation-optimizer';
export function optimizeOperations(schema, documents, options) {
    const newDocuments = optimizeDocuments(schema, documents.map(s => s.document), options);
    return newDocuments.map((document, index) => ({
        ...documents[index],
        location: documents[index]?.location || 'optimized by relay',
        document,
    }));
}
