import { Kind, print, } from 'graphql';
import sortBy from 'lodash.sortby';
import { normalizeWhiteSpace } from './normalize-whitespace.js';
// Cache the sorted nodes to avoid sorting the same nodes multiple times
const nodeSortCache = new WeakMap();
export function sortExecutableNodes(nodes) {
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
        if (isOfKindList(nodes, Kind.DIRECTIVE)) {
            return cacheResult(sortBy(nodes, 'name.value'));
        }
        if (isOfKindList(nodes, Kind.VARIABLE_DEFINITION)) {
            return cacheResult(sortBy(nodes, 'variable.name.value'));
        }
        if (isOfKindList(nodes, Kind.ARGUMENT)) {
            return cacheResult(sortBy(nodes, 'name.value'));
        }
        if (isOfKindList(nodes, [Kind.FIELD, Kind.FRAGMENT_SPREAD, Kind.INLINE_FRAGMENT])) {
            return cacheResult(sortBy(nodes, node => {
                if (node.kind === Kind.FIELD) {
                    return sortPrefixField + node.name.value;
                }
                else if (node.kind === Kind.FRAGMENT_SPREAD) {
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
        return cacheResult(sortBy(nodes, 'kind', 'name.value'));
    }
}
const sortPrefixField = '0';
const sortPrefixFragmentSpread = '1';
const sortPrefixInlineFragmentNode = '2';
function isOfKindList(nodes, kind) {
    return typeof kind === 'string' ? nodes[0].kind === kind : kind.includes(nodes[0].kind);
}
function buildInlineFragmentSelectionSetKey(nodes) {
    return normalizeWhiteSpace(nodes.map(node => print(node)).join(' '));
}
