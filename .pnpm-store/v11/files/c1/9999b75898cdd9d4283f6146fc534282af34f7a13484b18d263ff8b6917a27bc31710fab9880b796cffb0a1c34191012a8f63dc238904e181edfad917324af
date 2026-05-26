"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.optimizeOperations = optimizeOperations;
const relay_operation_optimizer_1 = require("@graphql-tools/relay-operation-optimizer");
function optimizeOperations(schema, documents, options) {
    const newDocuments = (0, relay_operation_optimizer_1.optimizeDocuments)(schema, documents.map(s => s.document), options);
    return newDocuments.map((document, index) => ({
        ...documents[index],
        location: documents[index]?.location || 'optimized by relay',
        document,
    }));
}
