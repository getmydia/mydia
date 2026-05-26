"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.generateDocumentHash = generateDocumentHash;
exports.normalizeAndPrintDocumentNode = normalizeAndPrintDocumentNode;
const tslib_1 = require("tslib");
const crypto = tslib_1.__importStar(require("crypto"));
const graphql_1 = require("graphql");
const documents_1 = require("@graphql-tools/documents");
const CLIENT_DIRECTIVE_NAME = 'client';
const CONNECTION_DIRECTIVE_NAME = 'connection';
/**
 * This function generates a hash from a document node.
 * When `sha256` algorithm is used, the hash should be prefixed with `sha256:`
 * https://github.com/graphql/graphql-over-http/blob/52d56fb36d51c17e08a920510a23bdc2f6a720be/spec/Appendix%20A%20--%20Persisted%20Documents.md#sha256-hex-document-identifier
 */
function generateDocumentHash(operation, algorithm) {
    if (typeof algorithm === 'function') {
        return algorithm(operation);
    }
    const shasum = crypto.createHash(algorithm);
    shasum.update(operation);
    const algorithmPrefix = algorithm === 'sha256' ? 'sha256:' : '';
    return algorithmPrefix + shasum.digest('hex');
}
/**
 * Normalizes and prints a document node.
 */
function normalizeAndPrintDocumentNode(documentNode) {
    /**
     * This removes all client specific directives/fields from the document
     * that the server does not know about.
     * In a future version this should be more configurable.
     * If you look at this and want to customize it.
     * Send a PR :)
     */
    const sanitizedDocument = (0, graphql_1.visit)(documentNode, {
        [graphql_1.Kind.FIELD](field) {
            if (field.directives?.some(directive => directive.name.value === CLIENT_DIRECTIVE_NAME)) {
                return null;
            }
        },
        [graphql_1.Kind.FRAGMENT_SPREAD](spread) {
            if (spread.directives?.some(directive => directive.name.value === CLIENT_DIRECTIVE_NAME)) {
                return null;
            }
        },
        [graphql_1.Kind.INLINE_FRAGMENT](fragment) {
            if (fragment.directives?.some(directive => directive.name.value === CLIENT_DIRECTIVE_NAME)) {
                return null;
            }
        },
        [graphql_1.Kind.DIRECTIVE](directive) {
            if (directive.name.value === CONNECTION_DIRECTIVE_NAME) {
                return null;
            }
        },
    });
    return (0, documents_1.printExecutableGraphQLDocument)(sanitizedDocument);
}
