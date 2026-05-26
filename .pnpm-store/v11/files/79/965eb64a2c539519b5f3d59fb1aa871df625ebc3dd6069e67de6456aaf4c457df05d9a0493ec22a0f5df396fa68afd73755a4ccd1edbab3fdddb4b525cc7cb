"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.plugins = void 0;
const helpers_js_1 = require("./helpers.js");
const types_js_1 = require("./types.js");
exports.plugins = [
    {
        name: `TypeScript ${(0, helpers_js_1.italic)('(required by other typescript plugins)')}`,
        package: '@graphql-codegen/typescript',
        value: 'typescript',
        pathInRepo: 'typescript/typescript',
        available: hasTag(types_js_1.Tags.typescript),
        shouldBeSelected: tags => oneOf(tags, types_js_1.Tags.angular, types_js_1.Tags.stencil) ||
            allOf(tags, types_js_1.Tags.typescript, types_js_1.Tags.react) ||
            noneOf(tags, types_js_1.Tags.flow),
        defaultExtension: '.ts',
    },
    {
        name: `TypeScript Operations ${(0, helpers_js_1.italic)('(operations and fragments)')}`,
        package: '@graphql-codegen/typescript-operations',
        value: 'typescript-operations',
        pathInRepo: 'typescript/operations',
        available: tags => allOf(tags, types_js_1.Tags.client, types_js_1.Tags.typescript) || hasTag(types_js_1.Tags.stencil)(tags),
        shouldBeSelected: tags => oneOf(tags, types_js_1.Tags.angular, types_js_1.Tags.stencil) || allOf(tags, types_js_1.Tags.typescript, types_js_1.Tags.react),
        defaultExtension: '.ts',
    },
    {
        name: `TypeScript Resolvers ${(0, helpers_js_1.italic)('(strongly typed resolve functions)')}`,
        package: '@graphql-codegen/typescript-resolvers',
        value: 'typescript-resolvers',
        pathInRepo: 'typescript/resolvers',
        available: tags => allOf(tags, types_js_1.Tags.node, types_js_1.Tags.typescript),
        shouldBeSelected: tags => noneOf(tags, types_js_1.Tags.flow),
        defaultExtension: '.ts',
    },
    {
        name: `Flow ${(0, helpers_js_1.italic)('(required by other flow plugins)')}`,
        package: '@graphql-codegen/flow',
        value: 'flow',
        pathInRepo: 'flow/flow',
        available: hasTag(types_js_1.Tags.flow),
        shouldBeSelected: tags => noneOf(tags, types_js_1.Tags.typescript),
        defaultExtension: '.js',
    },
    {
        name: `Flow Operations ${(0, helpers_js_1.italic)('(operations and fragments)')}`,
        package: '@graphql-codegen/flow-operations',
        value: 'flow-operations',
        pathInRepo: 'flow/operations',
        available: tags => allOf(tags, types_js_1.Tags.client, types_js_1.Tags.flow),
        shouldBeSelected: tags => noneOf(tags, types_js_1.Tags.typescript),
        defaultExtension: '.js',
    },
    {
        name: `Flow Resolvers ${(0, helpers_js_1.italic)('(strongly typed resolve functions)')}`,
        package: '@graphql-codegen/flow-resolvers',
        value: 'flow-resolvers',
        pathInRepo: 'flow/resolvers',
        available: tags => allOf(tags, types_js_1.Tags.node, types_js_1.Tags.flow),
        shouldBeSelected: tags => noneOf(tags, types_js_1.Tags.typescript),
        defaultExtension: '.js',
    },
    {
        name: `TypeScript Stencil Apollo ${(0, helpers_js_1.italic)('(typed components)')}`,
        package: '@graphql-codegen/typescript-stencil-apollo',
        value: 'typescript-stencil-apollo',
        pathInRepo: 'typescript/stencil-apollo',
        available: hasTag(types_js_1.Tags.stencil),
        shouldBeSelected: () => true,
        defaultExtension: '.tsx',
    },
    {
        name: `TypeScript MongoDB ${(0, helpers_js_1.italic)('(typed MongoDB objects)')}`,
        package: '@graphql-codegen/typescript-mongodb',
        value: 'typescript-mongodb',
        pathInRepo: 'typescript/mongodb',
        available: tags => allOf(tags, types_js_1.Tags.node, types_js_1.Tags.typescript),
        shouldBeSelected: () => false,
        defaultExtension: '.ts',
    },
    {
        name: `TypeScript GraphQL files modules ${(0, helpers_js_1.italic)('(declarations for .graphql files)')}`,
        package: '@graphql-codegen/typescript-graphql-files-modules',
        value: 'typescript-graphql-files-modules',
        pathInRepo: 'typescript/graphql-files-modules',
        available: tags => allOf(tags, types_js_1.Tags.client, types_js_1.Tags.typescript) || hasTag(types_js_1.Tags.stencil)(tags),
        shouldBeSelected: () => false,
        defaultExtension: '.ts',
    },
    {
        name: `TypeScript GraphQL document nodes ${(0, helpers_js_1.italic)('(embedded GraphQL document)')}`,
        package: '@graphql-codegen/typescript-document-nodes',
        value: 'typescript-document-nodes',
        pathInRepo: 'typescript/document-nodes',
        available: tags => allOf(tags, types_js_1.Tags.typescript) || hasTag(types_js_1.Tags.stencil)(tags),
        shouldBeSelected: () => false,
        defaultExtension: '.ts',
    },
    {
        name: `Introspection Fragment Matcher ${(0, helpers_js_1.italic)('(for Apollo Client)')}`,
        package: '@graphql-codegen/fragment-matcher',
        value: 'fragment-matcher',
        pathInRepo: 'other/fragment-matcher',
        available: tags => hasTag(types_js_1.Tags.client)(tags) || hasTag(types_js_1.Tags.angular)(tags) || hasTag(types_js_1.Tags.stencil)(tags),
        shouldBeSelected: () => false,
        defaultExtension: '.ts',
    },
    {
        name: `Urql Introspection ${(0, helpers_js_1.italic)('(for Urql Client)')}`,
        package: '@graphql-codegen/urql-introspection',
        value: 'urql-introspection',
        pathInRepo: 'other/urql-introspection',
        available: tags => hasTag(types_js_1.Tags.client)(tags) || hasTag(types_js_1.Tags.stencil)(tags),
        shouldBeSelected: () => false,
        defaultExtension: '.ts',
    },
    {
        name: `TypeScript Apollo Angular ${(0, helpers_js_1.italic)('(typed GQL services)')}`,
        package: '@graphql-codegen/typescript-apollo-angular',
        value: 'typescript-apollo-angular',
        pathInRepo: 'typescript/apollo-angular',
        available: hasTag(types_js_1.Tags.angular),
        shouldBeSelected: () => true,
        defaultExtension: '.ts',
    },
];
function hasTag(tag) {
    return (tags) => tags.includes(tag);
}
function oneOf(list, ...items) {
    return list.some(i => items.includes(i));
}
function noneOf(list, ...items) {
    return !list.some(i => items.includes(i));
}
function allOf(list, ...items) {
    return items.every(i => list.includes(i));
}
