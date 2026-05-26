"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.printExecutableGraphQLDocument = void 0;
const graphql_1 = require("graphql");
const normalize_whitespace_js_1 = require("./normalize-whitespace.js");
const sort_executable_document_js_1 = require("./sort-executable-document.js");
/**
 * Print an executable document node definition in a stable way.
 * All the nodes are sorted by name and the white space is reduced.
 */
function printExecutableGraphQLDocument(document) {
    const sortedDocument = (0, sort_executable_document_js_1.sortExecutableDocument)(document);
    const printedDocument = (0, graphql_1.print)(sortedDocument);
    return (0, normalize_whitespace_js_1.normalizeWhiteSpace)(printedDocument);
}
exports.printExecutableGraphQLDocument = printExecutableGraphQLDocument;
