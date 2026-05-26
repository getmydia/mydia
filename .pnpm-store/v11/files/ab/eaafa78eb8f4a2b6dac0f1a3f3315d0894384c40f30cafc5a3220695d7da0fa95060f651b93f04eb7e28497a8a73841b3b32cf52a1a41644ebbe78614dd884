"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.plugin = void 0;
exports.includeIntrospectionTypesDefinitions = includeIntrospectionTypesDefinitions;
const tslib_1 = require("tslib");
const graphql_1 = require("graphql");
const plugin_helpers_1 = require("@graphql-codegen/plugin-helpers");
const schema_ast_1 = require("@graphql-codegen/schema-ast");
const introspection_visitor_js_1 = require("./introspection-visitor.js");
const visitor_js_1 = require("./visitor.js");
tslib_1.__exportStar(require("./config.js"), exports);
tslib_1.__exportStar(require("./introspection-visitor.js"), exports);
tslib_1.__exportStar(require("./typescript-variables-to-object.js"), exports);
tslib_1.__exportStar(require("./visitor.js"), exports);
const plugin = (schema, documents, config) => {
    const { schema: _schema, ast } = (0, schema_ast_1.transformSchemaAST)(schema, config);
    const visitor = new visitor_js_1.TsVisitor(_schema, config);
    const visitorResult = (0, plugin_helpers_1.oldVisit)(ast, { leave: visitor });
    const introspectionDefinitions = includeIntrospectionTypesDefinitions(_schema, documents, config);
    const scalars = visitor.scalarsDefinition;
    const directiveArgumentAndInputFieldMappings = visitor.directiveArgumentAndInputFieldMappingsDefinition;
    return {
        prepend: [
            ...visitor.getEnumsImports(),
            ...visitor.getDirectiveArgumentAndInputFieldMappingsImports(),
            ...visitor.getScalarsImports(),
            ...visitor.getWrapperDefinitions(),
        ].filter(Boolean),
        content: [
            scalars,
            directiveArgumentAndInputFieldMappings,
            ...visitorResult.definitions,
            ...introspectionDefinitions,
        ]
            .filter(Boolean)
            .join('\n'),
    };
};
exports.plugin = plugin;
function includeIntrospectionTypesDefinitions(schema, documents, config) {
    const typeInfo = new graphql_1.TypeInfo(schema);
    const usedTypes = [];
    const documentsVisitor = (0, graphql_1.visitWithTypeInfo)(typeInfo, {
        Field() {
            const type = (0, graphql_1.getNamedType)(typeInfo.getType());
            if (type && (0, graphql_1.isIntrospectionType)(type) && !usedTypes.includes(type)) {
                usedTypes.push(type);
            }
        },
    });
    for (const doc of documents) {
        (0, graphql_1.visit)(doc.document, documentsVisitor);
    }
    const typesToInclude = [];
    for (const type of usedTypes) {
        collectTypes(type);
    }
    const visitor = new introspection_visitor_js_1.TsIntrospectionVisitor(schema, config, typesToInclude);
    const result = (0, plugin_helpers_1.oldVisit)((0, graphql_1.parse)((0, graphql_1.printIntrospectionSchema)(schema)), {
        leave: visitor,
    });
    // recursively go through each `usedTypes` and their children and collect all used types
    // we don't care about Interfaces, Unions and others, but Objects and Enums
    function collectTypes(type) {
        if (typesToInclude.includes(type)) {
            return;
        }
        typesToInclude.push(type);
        if ((0, graphql_1.isObjectType)(type)) {
            const fields = type.getFields();
            for (const key of Object.keys(fields)) {
                const field = fields[key];
                const type = (0, graphql_1.getNamedType)(field.type);
                collectTypes(type);
            }
        }
    }
    return result.definitions;
}
