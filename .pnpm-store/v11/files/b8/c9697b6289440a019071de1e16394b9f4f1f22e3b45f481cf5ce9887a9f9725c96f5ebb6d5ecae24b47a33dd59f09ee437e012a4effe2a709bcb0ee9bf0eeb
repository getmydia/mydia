"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.defaultDocumentsLoadOptions = exports.defaultSchemaLoadOptions = void 0;
exports.loadSchema = loadSchema;
exports.loadDocuments = loadDocuments;
const path_1 = require("path");
const graphql_1 = require("graphql");
const apollo_engine_loader_1 = require("@graphql-tools/apollo-engine-loader");
const code_file_loader_1 = require("@graphql-tools/code-file-loader");
const git_loader_1 = require("@graphql-tools/git-loader");
const github_loader_1 = require("@graphql-tools/github-loader");
const graphql_file_loader_1 = require("@graphql-tools/graphql-file-loader");
const json_file_loader_1 = require("@graphql-tools/json-file-loader");
const load_1 = require("@graphql-tools/load");
const url_loader_1 = require("@graphql-tools/url-loader");
exports.defaultSchemaLoadOptions = {
    assumeValidSDL: true,
    sort: true,
    convertExtensions: true,
    includeSources: true,
};
exports.defaultDocumentsLoadOptions = {
    sort: true,
    skipGraphQLImport: true,
};
async function loadSchema(schemaPointers, config) {
    try {
        const loaders = [
            new code_file_loader_1.CodeFileLoader(),
            new git_loader_1.GitLoader(),
            new github_loader_1.GithubLoader(),
            new graphql_file_loader_1.GraphQLFileLoader(),
            new json_file_loader_1.JsonFileLoader(),
            new url_loader_1.UrlLoader(),
            new apollo_engine_loader_1.ApolloEngineLoader(),
        ];
        const schema = await (0, load_1.loadSchema)(schemaPointers, {
            ...exports.defaultSchemaLoadOptions,
            loaders,
            ...config,
            ...config.config,
        });
        return schema;
    }
    catch (e) {
        throw new Error([
            `Failed to load schema from ${Object.keys(schemaPointers).join(',')}:`,
            printError(e),
            '\nGraphQL Code Generator supports:',
            '\n- ES Modules and CommonJS exports (export as default or named export "schema")',
            '- Introspection JSON File',
            '- URL of GraphQL endpoint',
            '- Multiple files with type definitions (glob expression)',
            '- String in config file',
            '\nTry to use one of above options and run codegen again.\n',
        ].join('\n'));
    }
}
async function loadDocuments(documentPointers, config) {
    const loaders = [
        new code_file_loader_1.CodeFileLoader({
            pluckConfig: {
                skipIndent: true,
            },
        }),
        new git_loader_1.GitLoader(),
        new github_loader_1.GithubLoader(),
        new graphql_file_loader_1.GraphQLFileLoader(),
    ];
    const ignore = [];
    for (const generatePath of Object.keys(config.generates)) {
        if ((0, path_1.extname)(generatePath) === '') {
            // we omit paths that don't resolve to a specific file
            continue;
        }
        ignore.push((0, path_1.join)(config.cwd || process.cwd(), generatePath));
    }
    try {
        const loadedFromToolkit = await (0, load_1.loadDocuments)(documentPointers, {
            ...exports.defaultDocumentsLoadOptions,
            ignore,
            loaders,
            ...config,
            ...config.config,
        });
        return loadedFromToolkit;
    }
    catch (error) {
        // NoTypeDefinitionsFound from `@graphql-tools/load` already has a message with pointer, so we can just rethrow the error
        if (error instanceof load_1.NoTypeDefinitionsFound) {
            throw error;
        }
        // For other errors, we need to add an error message with documentPointers, so it's better for DevX
        throw new Error([
            `Failed to load documents from ${Object.keys(documentPointers).join(',')}:`,
            printError(error),
        ].join('\n'));
    }
}
const printError = (error) => {
    if (error instanceof graphql_1.GraphQLError) {
        return String(error);
    }
    return [String(error.message || error), String(error.stack)].join('\n');
};
