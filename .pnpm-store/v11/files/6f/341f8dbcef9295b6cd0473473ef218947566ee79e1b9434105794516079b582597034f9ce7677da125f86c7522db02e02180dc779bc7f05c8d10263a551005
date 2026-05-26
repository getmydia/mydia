"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.addTypenameSelectionDocumentTransform = exports.preset = exports.babelOptimizerPlugin = void 0;
const tslib_1 = require("tslib");
const graphql_1 = require("graphql");
const addPlugin = tslib_1.__importStar(require("@graphql-codegen/add"));
const gqlTagPlugin = tslib_1.__importStar(require("@graphql-codegen/gql-tag-operations"));
const plugin_helpers_1 = require("@graphql-codegen/plugin-helpers");
const typedDocumentNodePlugin = tslib_1.__importStar(require("@graphql-codegen/typed-document-node"));
const typescriptOperationPlugin = tslib_1.__importStar(require("@graphql-codegen/typescript-operations"));
const visitor_plugin_common_1 = require("@graphql-codegen/visitor-plugin-common");
const fragmentMaskingPlugin = tslib_1.__importStar(require("./fragment-masking-plugin.js"));
const persisted_documents_js_1 = require("./persisted-documents.js");
const process_sources_js_1 = require("./process-sources.js");
var babel_js_1 = require("./babel.js");
Object.defineProperty(exports, "babelOptimizerPlugin", { enumerable: true, get: function () { return tslib_1.__importDefault(babel_js_1).default; } });
const isOutputFolderLike = (baseOutputDir) => baseOutputDir.endsWith('/');
exports.preset = {
    prepareDocuments: (outputFilePath, outputSpecificDocuments) => [
        ...outputSpecificDocuments,
        `!${outputFilePath}`,
    ],
    buildGeneratesSection: async (options) => {
        if (!isOutputFolderLike(options.baseOutputDir)) {
            throw new Error('[client-preset] target output should be a directory, ex: "src/gql/". Make sure you add "/" at the end of the directory path');
        }
        if (options.plugins.length > 0 &&
            Object.keys(options.plugins).some(p => p.startsWith('typescript'))) {
            throw new Error('[client-preset] providing typescript-based `plugins` with `preset: "client" leads to duplicated generated types');
        }
        const isPersistedOperations = !!options.presetConfig?.persistedDocuments;
        if (options.config.nullability?.errorHandlingClient) {
            options.schemaAst = await semanticToStrict(options.schemaAst);
            options.schema = (0, graphql_1.parse)((0, graphql_1.printSchema)(options.schemaAst));
        }
        const reexports = [];
        // the `client` preset is restricting the config options inherited from `typescript`, `typescript-operations` and others.
        const forwardedConfig = {
            scalars: options.config.scalars,
            defaultScalarType: options.config.defaultScalarType,
            strictScalars: options.config.strictScalars,
            namingConvention: options.config.namingConvention,
            useTypeImports: options.config.useTypeImports,
            arrayInputCoercion: options.config.arrayInputCoercion,
            enumType: options.config.enumType,
            enumValues: options.config.enumValues,
            futureProofEnums: options.config.futureProofEnums,
            nonOptionalTypename: options.config.nonOptionalTypename,
            avoidOptionals: options.config.avoidOptionals,
            documentMode: options.config.documentMode,
            skipTypeNameForRoot: options.config.skipTypeNameForRoot,
            customDirectives: options.config.customDirectives,
            immutableTypes: options.config.immutableTypes,
        };
        const visitor = new visitor_plugin_common_1.ClientSideBaseVisitor(options.schemaAst, [], options.config, options.config);
        let fragmentMaskingConfig = null;
        if (typeof options?.presetConfig?.fragmentMasking === 'object') {
            fragmentMaskingConfig = options.presetConfig.fragmentMasking;
        }
        else if (options?.presetConfig?.fragmentMasking !== false) {
            // `true` by default
            fragmentMaskingConfig = {};
        }
        const onExecutableDocumentNodeHook = options.presetConfig.onExecutableDocumentNode ?? null;
        const isMaskingFragments = fragmentMaskingConfig != null;
        const persistedDocuments = options.presetConfig.persistedDocuments
            ? {
                hashPropertyName: (typeof options.presetConfig.persistedDocuments === 'object' &&
                    options.presetConfig.persistedDocuments.hashPropertyName) ||
                    'hash',
                omitDefinitions: (typeof options.presetConfig.persistedDocuments === 'object' &&
                    options.presetConfig.persistedDocuments.mode) === 'replaceDocumentWithHash' || false,
                hashAlgorithm: (typeof options.presetConfig.persistedDocuments === 'object' &&
                    options.presetConfig.persistedDocuments.hashAlgorithm) ||
                    'sha256',
            }
            : null;
        const sourcesWithOperations = (0, process_sources_js_1.processSources)(options.documents, node => {
            if (node.kind === 'FragmentDefinition') {
                return visitor.getFragmentVariableName(node);
            }
            return visitor.getOperationVariableName(node);
        });
        const sources = sourcesWithOperations.map(({ source }) => source);
        const tdnFinished = createDeferred();
        const persistedDocumentsMap = new Map();
        const pluginMap = {
            ...options.pluginMap,
            [`add`]: addPlugin,
            [`typescript-operations`]: typescriptOperationPlugin,
            [`typed-document-node`]: {
                ...typedDocumentNodePlugin,
                plugin: async (...args) => {
                    try {
                        return await typedDocumentNodePlugin.plugin(...args);
                    }
                    finally {
                        tdnFinished.resolve();
                    }
                },
            },
            [`gen-dts`]: gqlTagPlugin,
        };
        function onExecutableDocumentNode(documentNode) {
            const meta = onExecutableDocumentNodeHook?.(documentNode);
            if (persistedDocuments) {
                const documentString = (0, persisted_documents_js_1.normalizeAndPrintDocumentNode)(documentNode);
                const hash = (0, persisted_documents_js_1.generateDocumentHash)(documentString, persistedDocuments.hashAlgorithm);
                persistedDocumentsMap.set(hash, documentString);
                return { ...meta, [persistedDocuments.hashPropertyName]: hash };
            }
            if (meta) {
                return meta;
            }
            return undefined;
        }
        const plugins = [
            { [`add`]: { content: `/* eslint-disable */` } },
            { [`typescript-operations`]: {} },
            {
                [`typed-document-node`]: {
                    unstable_onExecutableDocumentNode: onExecutableDocumentNode,
                    unstable_omitDefinitions: persistedDocuments?.omitDefinitions ?? false,
                },
            },
            ...options.plugins,
        ];
        const genDtsPlugins = [
            { [`add`]: { content: `/* eslint-disable */` } },
            { [`gen-dts`]: { sourcesWithOperations } },
        ];
        const gqlArtifactFileExtension = '.ts';
        reexports.push('gql');
        const config = {
            ...options.config,
            inlineFragmentTypes: isMaskingFragments ? 'mask' : options.config['inlineFragmentTypes'],
        };
        let fragmentMaskingFileGenerateConfig = null;
        const importExtension = (0, plugin_helpers_1.normalizeImportExtension)({
            emitLegacyCommonJSImports: options.config.emitLegacyCommonJSImports,
            importExtension: options.config.importExtension,
        });
        if (isMaskingFragments === true) {
            const fragmentMaskingArtifactFileExtension = '.ts';
            reexports.push('fragment-masking');
            fragmentMaskingFileGenerateConfig = {
                filename: `${options.baseOutputDir}fragment-masking${fragmentMaskingArtifactFileExtension}`,
                pluginMap: {
                    [`add`]: addPlugin,
                    [`fragment-masking`]: fragmentMaskingPlugin,
                },
                plugins: [
                    { [`add`]: { content: `/* eslint-disable */` } },
                    {
                        [`fragment-masking`]: {},
                    },
                ],
                schema: options.schema,
                config: {
                    useTypeImports: options.config.useTypeImports,
                    unmaskFunctionName: fragmentMaskingConfig.unmaskFunctionName,
                    emitLegacyCommonJSImports: options.config.emitLegacyCommonJSImports,
                    importExtension,
                    isStringDocumentMode: options.config.documentMode === visitor_plugin_common_1.DocumentMode.string,
                },
                documents: [],
                documentTransforms: options.documentTransforms,
            };
        }
        let indexFileGenerateConfig = null;
        if (reexports.length) {
            indexFileGenerateConfig = {
                filename: `${options.baseOutputDir}index.ts`,
                pluginMap: {
                    [`add`]: addPlugin,
                },
                plugins: [
                    {
                        [`add`]: {
                            content: reexports
                                .sort()
                                .map(moduleName => `export * from "./${moduleName}${importExtension}";`)
                                .join('\n'),
                        },
                    },
                ],
                schema: options.schema,
                config: {},
                documents: [],
                documentTransforms: options.documentTransforms,
            };
        }
        return [
            {
                filename: `${options.baseOutputDir}graphql.ts`,
                plugins,
                pluginMap,
                schema: options.schema,
                config: {
                    inlineFragmentTypes: isMaskingFragments ? 'mask' : options.config['inlineFragmentTypes'],
                    ...forwardedConfig,
                },
                documents: sources,
                documentTransforms: options.documentTransforms,
            },
            {
                filename: `${options.baseOutputDir}gql${gqlArtifactFileExtension}`,
                plugins: genDtsPlugins,
                pluginMap,
                schema: options.schema,
                config: {
                    ...config,
                    gqlTagName: options.presetConfig.gqlTagName || 'graphql',
                },
                documents: sources,
                documentTransforms: options.documentTransforms,
            },
            ...(isPersistedOperations
                ? [
                    {
                        filename: `${options.baseOutputDir}persisted-documents.json`,
                        plugins: [
                            {
                                [`persisted-operations`]: {},
                            },
                        ],
                        pluginMap: {
                            [`persisted-operations`]: {
                                plugin: async () => {
                                    await tdnFinished.promise;
                                    return {
                                        content: JSON.stringify(Object.fromEntries(persistedDocumentsMap.entries()), null, 2),
                                    };
                                },
                            },
                        },
                        schema: options.schema,
                        config: {},
                        documents: sources,
                        documentTransforms: options.documentTransforms,
                    },
                ]
                : []),
            ...(fragmentMaskingFileGenerateConfig ? [fragmentMaskingFileGenerateConfig] : []),
            ...(indexFileGenerateConfig ? [indexFileGenerateConfig] : []),
        ];
    },
};
function createDeferred() {
    const d = {};
    d.promise = new Promise((resolve, reject) => {
        d.resolve = resolve;
        d.reject = reject;
    });
    return d;
}
const semanticToStrict = async (schema) => {
    try {
        const sock = await Promise.resolve().then(() => tslib_1.__importStar(require('graphql-sock')));
        return sock.semanticToStrict(schema);
    }
    catch {
        throw new Error("To use the `nullability.errorHandlingClient` option, you must install the 'graphql-sock' package.");
    }
};
var add_typename_selection_document_transform_js_1 = require("./add-typename-selection-document-transform.js");
Object.defineProperty(exports, "addTypenameSelectionDocumentTransform", { enumerable: true, get: function () { return add_typename_selection_document_transform_js_1.addTypenameSelectionDocumentTransform; } });
