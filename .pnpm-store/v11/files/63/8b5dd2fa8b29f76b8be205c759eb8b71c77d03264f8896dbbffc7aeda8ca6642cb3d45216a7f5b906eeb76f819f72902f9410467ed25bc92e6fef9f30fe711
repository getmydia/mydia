"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.UrqlVisitor = exports.validate = exports.plugin = void 0;
const path_1 = require("path");
const graphql_1 = require("graphql");
const plugin_helpers_1 = require("@graphql-codegen/plugin-helpers");
const visitor_js_1 = require("./visitor.js");
Object.defineProperty(exports, "UrqlVisitor", { enumerable: true, get: function () { return visitor_js_1.UrqlVisitor; } });
const plugin = (schema, documents, config) => {
    const allAst = (0, graphql_1.concatAST)(documents.map(v => v.document));
    const allFragments = [
        ...allAst.definitions.filter(d => d.kind === graphql_1.Kind.FRAGMENT_DEFINITION).map(fragmentDef => ({
            node: fragmentDef,
            name: fragmentDef.name.value,
            onType: fragmentDef.typeCondition.name.value,
            isExternal: false,
        })),
        ...(config.externalFragments || []),
    ];
    const visitor = new visitor_js_1.UrqlVisitor(schema, allFragments, config);
    const visitorResult = (0, plugin_helpers_1.oldVisit)(allAst, { leave: visitor });
    return {
        prepend: visitor.getImports(),
        content: [
            visitor.fragments,
            ...visitorResult.definitions.filter(t => typeof t === 'string'),
        ].join('\n'),
    };
};
exports.plugin = plugin;
const validate = async (schema, documents, config, outputFile) => {
    if (config.withComponent === true) {
        if ((0, path_1.extname)(outputFile) !== '.tsx') {
            throw new Error(`Plugin "typescript-urql" requires extension to be ".tsx" when withComponent: true is set!`);
        }
    }
    else if ((0, path_1.extname)(outputFile) !== '.ts' && (0, path_1.extname)(outputFile) !== '.tsx') {
        throw new Error(`Plugin "typescript-urql" requires extension to be ".ts" or ".tsx"!`);
    }
};
exports.validate = validate;
