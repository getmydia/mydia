"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.addTypenameSelectionDocumentTransform = void 0;
const graphql_1 = require("graphql");
/**
 * Automatically adds `__typename` selections to every object type in your GraphQL document except the root node in subscriptions since a single root field is expected (https://spec.graphql.org/draft/#sec-Single-root-field).
 * This is useful for GraphQL Clients such as Apollo Client or urql that need typename information for their cache to function.
 */
exports.addTypenameSelectionDocumentTransform = {
    transform({ documents }) {
        return documents.map(document => ({
            ...document,
            document: document.document
                ? (0, graphql_1.visit)(document.document, {
                    SelectionSet(node, _, parent) {
                        const isSubscriptionRoot = typeof parent?.kind === 'string' &&
                            parent.kind === 'OperationDefinition' &&
                            parent.operation === 'subscription';
                        if (!isSubscriptionRoot &&
                            !node.selections.find(selection => selection.kind === 'Field' && selection.name.value === '__typename')) {
                            return {
                                ...node,
                                selections: [
                                    {
                                        kind: graphql_1.Kind.FIELD,
                                        name: {
                                            kind: graphql_1.Kind.NAME,
                                            value: '__typename',
                                        },
                                    },
                                    ...node.selections,
                                ],
                            };
                        }
                        return undefined;
                    },
                })
                : undefined,
        }));
    },
};
