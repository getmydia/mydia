"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sortExecutableDocument = void 0;
const graphql_1 = require("graphql");
const sort_executable_nodes_js_1 = require("./sort-executable-nodes.js");
/**
 * Sort an executable GraphQL document.
 */
function sortExecutableDocument(document) {
    const ignoredNodes = new WeakSet();
    const ignoredSelectionsArr = new Set();
    const ignoredFragments = new Set();
    return (0, graphql_1.visit)(document, {
        Document(node) {
            return {
                ...node,
                definitions: (0, sort_executable_nodes_js_1.sortExecutableNodes)(node.definitions),
            };
        },
        OperationDefinition(node) {
            if (node.operation === 'mutation') {
                ignoredNodes.add(node.selectionSet);
                ignoredSelectionsArr.add(node.selectionSet.selections);
            }
            return {
                ...node,
                variableDefinitions: (0, sort_executable_nodes_js_1.sortExecutableNodes)(node.variableDefinitions),
            };
        },
        SelectionSet(node) {
            if (ignoredNodes.has(node)) {
                ignoredSelectionsArr.add(node.selections);
                return node;
            }
            return {
                ...node,
                selections: (0, sort_executable_nodes_js_1.sortExecutableNodes)(node.selections),
            };
        },
        FragmentSpread(node, _key, parent) {
            if (Array.isArray(parent) && ignoredSelectionsArr.has(parent)) {
                ignoredFragments.add(node.name.value);
            }
            return {
                ...node,
                directives: (0, sort_executable_nodes_js_1.sortExecutableNodes)(node.directives),
            };
        },
        InlineFragment(node, _key, parent) {
            if (Array.isArray(parent) && ignoredSelectionsArr.has(parent)) {
                ignoredNodes.add(node.selectionSet);
                ignoredSelectionsArr.add(node.selectionSet.selections);
                return node;
            }
            return {
                ...node,
                directives: (0, sort_executable_nodes_js_1.sortExecutableNodes)(node.directives),
            };
        },
        FragmentDefinition(node) {
            if (ignoredFragments.has(node.name.value)) {
                return node;
            }
            return {
                ...node,
                directives: (0, sort_executable_nodes_js_1.sortExecutableNodes)(node.directives),
                variableDefinitions: (0, sort_executable_nodes_js_1.sortExecutableNodes)(node.variableDefinitions),
            };
        },
        Directive(node) {
            return { ...node, arguments: (0, sort_executable_nodes_js_1.sortExecutableNodes)(node.arguments) };
        },
    });
}
exports.sortExecutableDocument = sortExecutableDocument;
