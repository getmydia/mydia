"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.TypeScriptDocumentsVisitor = exports.plugin = void 0;
const graphql_1 = require("graphql");
const plugin_helpers_1 = require("@graphql-codegen/plugin-helpers");
const schema_ast_1 = require("@graphql-codegen/schema-ast");
const visitor_plugin_common_1 = require("@graphql-codegen/visitor-plugin-common");
const visitor_js_1 = require("./visitor.js");
Object.defineProperty(exports, "TypeScriptDocumentsVisitor", { enumerable: true, get: function () { return visitor_js_1.TypeScriptDocumentsVisitor; } });
const plugin = async (inputSchema, rawDocuments, config, { outputFile }) => {
    const schema = config.nullability?.errorHandlingClient
        ? await semanticToStrict(inputSchema)
        : inputSchema;
    const documents = config.flattenGeneratedTypes
        ? (0, visitor_plugin_common_1.optimizeOperations)(schema, rawDocuments, {
            includeFragments: config.flattenGeneratedTypesIncludeFragments,
        })
        : rawDocuments;
    const parsedDocuments = documents.reduce((prev, document) => {
        prev.all.documentFiles.push(document);
        prev.all.documentNodes.push(document.document);
        // `!document.type` case could happen in a few scenarios:
        // - the plugin is programmatically triggered
        // - in existing tests
        if (!document.type || document.type === 'standard') {
            prev.standard.documentFiles.push(document);
            prev.standard.documentNodes.push(document.document);
        }
        return prev;
    }, {
        all: { documentFiles: [], documentNodes: [] },
        standard: { documentFiles: [], documentNodes: [] },
    });
    // For Fragment types to resolve correctly, we must get read all docs (`standard` and `external`)
    // Fragment types are usually (but not always) in `external` files in certain setup, like a monorepo.
    const allDocumentsAST = (0, graphql_1.concatAST)(parsedDocuments.all.documentNodes);
    const visitor = new visitor_js_1.TypeScriptDocumentsVisitor(schema, config, allDocumentsAST, outputFile);
    // We only visit `standard` documents to generate types.
    // `external` documents are included as references for typechecking and completeness i.e. only used for reading purposes, no writing.
    const documentsToVisitAST = (0, graphql_1.concatAST)(parsedDocuments.standard.documentNodes);
    const operationsResult = (0, plugin_helpers_1.oldVisit)(documentsToVisitAST, {
        leave: visitor,
    });
    const operationsDefinitions = operationsResult.definitions;
    if (config.addOperationExport) {
        for (const d of allDocumentsAST.definitions) {
            if ('name' in d) {
                operationsDefinitions.push(`export declare const ${d.name.value}: import("graphql").DocumentNode;`);
            }
        }
    }
    const schemaTypes = (0, plugin_helpers_1.oldVisit)((0, schema_ast_1.transformSchemaAST)(schema, config).ast, { leave: visitor });
    // IMPORTANT: when a visitor leaves a node with no transformation logic,
    // It will leave the node as an object.
    // Here, we filter in nodes that have been turned into strings, i.e. they have been transformed
    // This way, we do not have to explicitly declare a method for every node type to convert them to null
    const schemaTypesDefinitions = schemaTypes.definitions.filter(def => typeof def === 'string');
    let content = [...schemaTypesDefinitions, ...operationsDefinitions].join('\n');
    if (config.globalNamespace) {
        content = `
    declare global {
      ${content}
    }`;
    }
    return {
        prepend: [
            ...visitor.getImports(),
            ...visitor.getExternalSchemaTypeImports(),
            ...visitor.getEnumsImports(),
            ...visitor.getScalarsImports(),
            ...visitor.getGlobalDeclarations(visitor.config.noExport),
            visitor.getExactUtilityType(),
            visitor.getIncrementalUtilityType(),
        ],
        content,
    };
};
exports.plugin = plugin;
const semanticToStrict = async (schema) => {
    try {
        const sock = await Promise.resolve().then(() => __importStar(require('graphql-sock')));
        return sock.semanticToStrict(schema);
    }
    catch {
        throw new Error("To use the `nullability.errorHandlingClient` option, you must install the 'graphql-sock' package.");
    }
};
