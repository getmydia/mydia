"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const tslib_1 = require("tslib");
const path = tslib_1.__importStar(require("path"));
const graphql_1 = require("graphql");
const helper_plugin_utils_1 = require("@babel/helper-plugin-utils");
const template_1 = tslib_1.__importDefault(require("@babel/template"));
const visitor_plugin_common_1 = require("@graphql-codegen/visitor-plugin-common");
const noopSchema = (0, graphql_1.buildSchema)(`type Query { _: Int }`);
exports.default = (0, helper_plugin_utils_1.declare)((api, opts) => {
    const visitor = new visitor_plugin_common_1.ClientSideBaseVisitor(noopSchema, [], {}, {});
    const artifactDirectory = opts['artifactDirectory'] ?? '';
    const gqlTagName = opts['gqlTagName'] || 'gql';
    let program;
    return {
        name: 'client-preset',
        visitor: {
            Program(path) {
                program = path;
            },
            CallExpression(path, state) {
                if (path.node.callee.type !== 'Identifier' || path.node.callee.name !== gqlTagName) {
                    return;
                }
                const [argument] = path.node.arguments;
                if (argument == null) {
                    return;
                }
                if (argument.type !== 'TemplateLiteral') {
                    return;
                }
                const [content] = argument.quasis;
                const ast = (0, graphql_1.parse)(content.value.raw);
                const [firstDefinition] = ast.definitions;
                if (firstDefinition.kind !== 'FragmentDefinition' &&
                    firstDefinition.kind !== 'OperationDefinition') {
                    return;
                }
                if (firstDefinition.name == null) {
                    return;
                }
                const operationOrFragmentName = firstDefinition.kind === 'OperationDefinition'
                    ? visitor.getOperationVariableName(firstDefinition)
                    : visitor.getFragmentVariableName(firstDefinition);
                const importPath = getRelativeImportPath(state, artifactDirectory);
                const importDeclaration = template_1.default.smart(`
          import { %%importName%% } from %%importPath%%
        `);
                program.unshiftContainer('body', importDeclaration({
                    importName: api.types.identifier(operationOrFragmentName),
                    importPath: api.types.stringLiteral(importPath),
                }));
                path.replaceWith(api.types.identifier(operationOrFragmentName));
            },
        },
    };
});
function getRelativeImportPath(state, artifactDirectory, fileToRequire = 'graphql') {
    if (state.file == null) {
        throw new Error('Babel state is missing expected file name');
    }
    const { filename } = state.file.opts;
    const relative = path.relative(path.dirname(filename), path.resolve(artifactDirectory));
    const relativeReference = relative.length === 0 || !relative.startsWith('.') ? './' : '';
    const platformSpecificPath = relativeReference + path.join(relative, fileToRequire);
    // ensure windows paths are written as unix paths
    return platformSpecificPath.split(path.sep).join(path.posix.sep);
}
