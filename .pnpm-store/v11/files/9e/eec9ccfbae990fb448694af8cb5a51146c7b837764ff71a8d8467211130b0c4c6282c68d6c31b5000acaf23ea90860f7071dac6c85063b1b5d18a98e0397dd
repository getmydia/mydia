"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.TypeScriptDocumentNodesVisitor = void 0;
const tslib_1 = require("tslib");
const auto_bind_1 = tslib_1.__importDefault(require("auto-bind"));
const visitor_plugin_common_1 = require("@graphql-codegen/visitor-plugin-common");
class TypeScriptDocumentNodesVisitor extends visitor_plugin_common_1.ClientSideBaseVisitor {
    pluginConfig;
    constructor(schema, fragments, config, documents) {
        super(schema, fragments, {
            documentNodeImport: '@graphql-typed-document-node/core#TypedDocumentNode',
            ...config,
            documentMode: config.documentMode || visitor_plugin_common_1.DocumentMode.documentNodeImportFragments,
        }, {}, documents);
        this.pluginConfig = config;
        (0, auto_bind_1.default)(this);
        // We need to make sure it's there because in this mode, the base plugin doesn't add the import
        if (this.config.documentMode === visitor_plugin_common_1.DocumentMode.graphQLTag) {
            const documentNodeImport = this._parseImport(this.config.documentNodeImport || 'graphql#DocumentNode');
            const tagImport = this._generateImport(documentNodeImport, 'DocumentNode', true);
            this._imports.add(tagImport);
        }
        else if (this.config.documentMode === visitor_plugin_common_1.DocumentMode.string) {
            const tagImport = this._generateImport({
                moduleName: '@graphql-typed-document-node/core',
                propName: 'DocumentTypeDecoration',
            }, 'DocumentTypeDecoration', true);
            this._imports.add(tagImport);
        }
    }
    SelectionSet(node, _, parent) {
        if (!this.pluginConfig.addTypenameToSelectionSets) {
            return;
        }
        // Don't add __typename to OperationDefinitions.
        if (parent && parent.kind === 'OperationDefinition') {
            return;
        }
        // No changes if no selections.
        const { selections } = node;
        if (!selections) {
            return;
        }
        // If selections already have a __typename or is introspection do nothing.
        const hasTypename = selections.some(selection => selection.kind === 'Field' &&
            (selection.name.value === '__typename' || selection.name.value.lastIndexOf('__', 0) === 0));
        if (hasTypename) {
            return;
        }
        return {
            ...node,
            selections: [
                ...selections,
                {
                    kind: 'Field',
                    name: {
                        kind: 'Name',
                        value: '__typename',
                    },
                },
            ],
        };
    }
    getDocumentNodeSignature(resultType, variablesTypes, node) {
        const shouldUseImportPrefix = !!this.config.importOperationTypesFrom;
        const resultImportPrefix = shouldUseImportPrefix && resultType !== 'unknown' ? 'Types.' : '';
        const variablesImportPrefix = shouldUseImportPrefix && variablesTypes !== 'unknown' ? 'Types.' : '';
        if (this.config.documentMode === visitor_plugin_common_1.DocumentMode.documentNode ||
            this.config.documentMode === visitor_plugin_common_1.DocumentMode.documentNodeImportFragments ||
            this.config.documentMode === visitor_plugin_common_1.DocumentMode.graphQLTag) {
            return ` as unknown as DocumentNode<${resultImportPrefix}${resultType}, ${variablesImportPrefix}${variablesTypes}>`;
        }
        if (this.config.documentMode === visitor_plugin_common_1.DocumentMode.string) {
            return ` as unknown as TypedDocumentString<${resultImportPrefix}${resultType}, ${variablesImportPrefix}${variablesTypes}>`;
        }
        return super.getDocumentNodeSignature(resultType, variablesTypes, node);
    }
}
exports.TypeScriptDocumentNodesVisitor = TypeScriptDocumentNodesVisitor;
