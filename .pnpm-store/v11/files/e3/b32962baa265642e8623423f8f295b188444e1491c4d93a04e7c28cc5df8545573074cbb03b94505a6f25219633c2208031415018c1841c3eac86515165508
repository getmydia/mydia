"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.validate = exports.plugin = void 0;
const path_1 = require("path");
const graphql_1 = require("graphql");
const plugin_helpers_1 = require("@graphql-codegen/plugin-helpers");
const visitor_plugin_common_1 = require("@graphql-codegen/visitor-plugin-common");
const visitor_js_1 = require("./visitor.js");
const plugin = (schema, rawDocuments, config) => {
    const documents = config.flattenGeneratedTypes
        ? (0, visitor_plugin_common_1.optimizeOperations)(schema, rawDocuments)
        : rawDocuments;
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
    const visitor = new visitor_js_1.TypeScriptDocumentNodesVisitor(schema, allFragments, config, documents);
    const visitorResult = (0, plugin_helpers_1.oldVisit)(allAst, { leave: visitor });
    let content = [];
    if (config.documentMode === visitor_plugin_common_1.DocumentMode.string) {
        content = [
            `\
export class TypedDocumentString<TResult, TVariables>
  extends String
  implements DocumentTypeDecoration<TResult, TVariables>
{
  __apiType?: NonNullable<DocumentTypeDecoration<TResult, TVariables>['__apiType']>;
  private value: string;
  public __meta__?: Record<string, any> | undefined;

  constructor(value: string, __meta__?: Record<string, any> | undefined) {
    super(value);
    this.value = value;
    this.__meta__ = __meta__;
  }

  override toString(): string & DocumentTypeDecoration<TResult, TVariables> {
    return this.value;
  }
}`,
        ];
    }
    return {
        prepend: allAst.definitions.length === 0 ? [] : visitor.getImports(),
        content: [
            ...content,
            visitor.fragments,
            ...visitorResult.definitions.filter(t => typeof t === 'string'),
        ].join('\n'),
    };
};
exports.plugin = plugin;
const validate = async (_schema, _documents, _config, outputFile) => {
    if ((0, path_1.extname)(outputFile) !== '.ts' && (0, path_1.extname)(outputFile) !== '.tsx') {
        throw new Error(`Plugin "typed-document-node" requires extension to be ".ts" or ".tsx"!`);
    }
};
exports.validate = validate;
