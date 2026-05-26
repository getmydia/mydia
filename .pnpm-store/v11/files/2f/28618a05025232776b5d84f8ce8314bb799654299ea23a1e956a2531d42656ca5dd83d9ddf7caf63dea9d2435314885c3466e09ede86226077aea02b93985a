import { type DocumentNode } from 'graphql';
/**
 * This function generates a hash from a document node.
 * When `sha256` algorithm is used, the hash should be prefixed with `sha256:`
 * https://github.com/graphql/graphql-over-http/blob/52d56fb36d51c17e08a920510a23bdc2f6a720be/spec/Appendix%20A%20--%20Persisted%20Documents.md#sha256-hex-document-identifier
 */
export declare function generateDocumentHash(operation: string, algorithm: 'sha1' | 'sha256' | (string & {}) | ((operation: string) => string)): string;
/**
 * Normalizes and prints a document node.
 */
export declare function normalizeAndPrintDocumentNode(documentNode: DocumentNode): string;
