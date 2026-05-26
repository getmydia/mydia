"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.CodegenExtension = void 0;
exports.findAndLoadGraphQLConfig = findAndLoadGraphQLConfig;
const graphql_config_1 = require("graphql-config");
const apollo_engine_loader_1 = require("@graphql-tools/apollo-engine-loader");
const code_file_loader_1 = require("@graphql-tools/code-file-loader");
const git_loader_1 = require("@graphql-tools/git-loader");
const github_loader_1 = require("@graphql-tools/github-loader");
const CodegenExtension = (api) => {
    // Schema
    api.loaders.schema.register(new code_file_loader_1.CodeFileLoader({
        pluckConfig: {
            skipIndent: true,
        },
    }));
    api.loaders.schema.register(new git_loader_1.GitLoader());
    api.loaders.schema.register(new github_loader_1.GithubLoader());
    api.loaders.schema.register(new apollo_engine_loader_1.ApolloEngineLoader());
    // Documents
    api.loaders.documents.register(new code_file_loader_1.CodeFileLoader({
        pluckConfig: {
            skipIndent: true,
        },
    }));
    api.loaders.documents.register(new git_loader_1.GitLoader());
    api.loaders.documents.register(new github_loader_1.GithubLoader());
    return {
        name: 'codegen',
    };
};
exports.CodegenExtension = CodegenExtension;
async function findAndLoadGraphQLConfig(filepath) {
    const config = await (0, graphql_config_1.loadConfig)({
        filepath,
        rootDir: process.cwd(),
        extensions: [exports.CodegenExtension],
        throwOnEmpty: false,
        throwOnMissing: false,
    });
    if (isGraphQLConfig(config)) {
        return config;
    }
}
// Kamil: user might load a config that is not GraphQL Config
//        so we need to check if it's a regular config or not
function isGraphQLConfig(config) {
    if (!config) {
        return false;
    }
    try {
        return config.getDefault().hasExtension('codegen');
    }
    catch { }
    try {
        for (const projectName in config.projects) {
            if (Object.prototype.hasOwnProperty.call(config.projects, projectName)) {
                const project = config.projects[projectName];
                if (project.hasExtension('codegen')) {
                    return true;
                }
            }
        }
    }
    catch { }
    return false;
}
