"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.optimizeDocuments = optimizeDocuments;
const tslib_1 = require("tslib");
const graphql_1 = require("graphql");
const CompilerContext_js_1 = tslib_1.__importDefault(require("@ardatan/relay-compiler/lib/core/CompilerContext.js"));
const IRPrinter_js_1 = require("@ardatan/relay-compiler/lib/core/IRPrinter.js");
const RelayParser_js_1 = require("@ardatan/relay-compiler/lib/core/RelayParser.js");
const Schema_js_1 = require("@ardatan/relay-compiler/lib/core/Schema.js");
const ApplyFragmentArgumentTransform_js_1 = require("@ardatan/relay-compiler/lib/transforms/ApplyFragmentArgumentTransform.js");
const FlattenTransform_js_1 = require("@ardatan/relay-compiler/lib/transforms/FlattenTransform.js");
const InlineFragmentsTransform_js_1 = require("@ardatan/relay-compiler/lib/transforms/InlineFragmentsTransform.js");
const SkipRedundantNodesTransform_js_1 = require("@ardatan/relay-compiler/lib/transforms/SkipRedundantNodesTransform.js");
const utils_1 = require("@graphql-tools/utils");
function optimizeDocuments(schema, documents, options = {}) {
    options = {
        noLocation: true,
        ...options,
    };
    // @TODO way for users to define directives they use, otherwise relay will throw an unknown directive error
    // Maybe we can scan the queries and add them dynamically without users having to do some extra stuff
    // transformASTSchema creates a new schema instance instead of mutating the old one
    const adjustedSchema = (0, Schema_js_1.create)((0, utils_1.printSchemaWithDirectives)(schema, options));
    const documentAsts = (0, graphql_1.concatAST)(documents);
    const relayDocuments = (0, RelayParser_js_1.transform)(adjustedSchema, documentAsts.definitions);
    const result = [];
    if (options.includeFragments) {
        const fragmentCompilerContext = new CompilerContext_js_1.default(adjustedSchema)
            .addAll(relayDocuments)
            .applyTransforms([
            ApplyFragmentArgumentTransform_js_1.transform,
            (0, FlattenTransform_js_1.transformWithOptions)({ flattenAbstractTypes: false }),
            SkipRedundantNodesTransform_js_1.transform,
        ]);
        result.push(...fragmentCompilerContext
            .documents()
            .filter(doc => doc.kind === 'Fragment')
            .map(doc => (0, graphql_1.parse)((0, IRPrinter_js_1.print)(adjustedSchema, doc), options)));
    }
    const queryCompilerContext = new CompilerContext_js_1.default(adjustedSchema)
        .addAll(relayDocuments)
        .applyTransforms([
        ApplyFragmentArgumentTransform_js_1.transform,
        InlineFragmentsTransform_js_1.transform,
        (0, FlattenTransform_js_1.transformWithOptions)({ flattenAbstractTypes: false }),
        SkipRedundantNodesTransform_js_1.transform,
    ]);
    result.push(...queryCompilerContext.documents().map(doc => (0, graphql_1.parse)((0, IRPrinter_js_1.print)(adjustedSchema, doc), options)));
    return result;
}
