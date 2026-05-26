"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sortExecutableNodes = void 0;
const tslib_1 = require("tslib");
const graphql_1 = require("graphql");
const lodash_sortby_1 = tslib_1.__importDefault(require("lodash.sortby"));
const normalize_whitespace_js_1 = require("./normalize-whitespace.js");
// Cache the sorted nodes to avoid sorting the same nodes multiple times
const nodeSortCache = new WeakMap();
function sortExecutableNodes(nodes) {
    if (nodes) {
        const shortcutNodes = nodeSortCache.get(nodes);
        if (shortcutNodes) {
            return shortcutNodes;
        }
        const cacheResult = (resultNodes) => {
            nodeSortCache.set(nodes, resultNodes);
            return resultNodes;
        };
        if (nodes.length === 0) {
            return [];
        }
        if (isOfKindList(nodes, graphql_1.Kind.DIRECTIVE)) {
            return cacheResult((0, lodash_sortby_1.default)(nodes, 'name.value'));
        }
        if (isOfKindList(nodes, graphql_1.Kind.VARIABLE_DEFINITION)) {
            return cacheResult((0, lodash_sortby_1.default)(nodes, 'variable.name.value'));
        }
        if (isOfKindList(nodes, graphql_1.Kind.ARGUMENT)) {
            return cacheResult((0, lodash_sortby_1.default)(nodes, 'name.value'));
        }
        if (isOfKindList(nodes, [graphql_1.Kind.FIELD, graphql_1.Kind.FRAGMENT_SPREAD, graphql_1.Kind.INLINE_FRAGMENT])) {
            return cacheResult((0, lodash_sortby_1.default)(nodes, node => {
                if (node.kind === graphql_1.Kind.FIELD) {
                    return sortPrefixField + node.name.value;
                }
                else if (node.kind === graphql_1.Kind.FRAGMENT_SPREAD) {
                    return sortPrefixFragmentSpread + node.name.value;
                }
                else {
                    const typeCondition = node.typeCondition?.name.value ?? '';
                    // if you have a better idea, send a PR :)
                    const sortedNodes = buildInlineFragmentSelectionSetKey(cacheResult(sortExecutableNodes(node.selectionSet.selections)));
                    return sortPrefixInlineFragmentNode + typeCondition + sortedNodes;
                }
            }));
        }
        return cacheResult((0, lodash_sortby_1.default)(nodes, 'kind', 'name.value'));
    }
}
exports.sortExecutableNodes = sortExecutableNodes;
const sortPrefixField = '0';
const sortPrefixFragmentSpread = '1';
const sortPrefixInlineFragmentNode = '2';
function isOfKindList(nodes, kind) {
    return typeof kind === 'string' ? nodes[0].kind === kind : kind.includes(nodes[0].kind);
}
function buildInlineFragmentSelectionSetKey(nodes) {
    return (0, normalize_whitespace_js_1.normalizeWhiteSpace)(nodes.map(node => (0, graphql_1.print)(node)).join(' '));
}
