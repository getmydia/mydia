"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.executeCodegen = executeCodegen;
const tslib_1 = require("tslib");
const fs_1 = tslib_1.__importDefault(require("fs"));
const module_1 = require("module");
const os_1 = require("os");
const path_1 = tslib_1.__importDefault(require("path"));
const graphql_1 = require("graphql");
const listr2_1 = require("listr2");
const core_1 = require("@graphql-codegen/core");
const plugin_helpers_1 = require("@graphql-codegen/plugin-helpers");
const load_1 = require("@graphql-tools/load");
const merge_1 = require("@graphql-tools/merge");
const config_js_1 = require("./config.js");
const documentTransforms_js_1 = require("./documentTransforms.js");
const plugins_js_1 = require("./plugins.js");
const presets_js_1 = require("./presets.js");
const debugging_js_1 = require("./utils/debugging.js");
/**
 * Poor mans ESM detection.
 * Looking at this and you have a better method?
 * Send a PR.
 */
const isESMModule = (typeof __dirname === 'string') === false;
const makeDefaultLoader = (from) => {
    if (fs_1.default.statSync(from).isDirectory()) {
        from = path_1.default.join(from, '__fake.js');
    }
    const relativeRequire = (0, module_1.createRequire)(from);
    return async (mod) => {
        return Promise.resolve(`${isESMModule
            ? /**
               * For ESM we currently have no "resolve path" solution
               * as import.meta is unavailable in a CommonJS context
               * and furthermore unavailable in stable Node.js.
               **/
                mod
            : relativeRequire.resolve(mod)}`).then(s => tslib_1.__importStar(require(s)));
    };
};
function createCache() {
    const cache = new Map();
    return function ensure(namespace, key, factory) {
        const cacheKey = `${namespace}:${key}`;
        const cachedValue = cache.get(cacheKey);
        if (cachedValue) {
            return cachedValue;
        }
        const value = factory();
        cache.set(cacheKey, value);
        return value;
    };
}
async function executeCodegen(input) {
    const context = (0, config_js_1.ensureContext)(input);
    const config = context.getConfig();
    const pluginContext = context.getPluginContext();
    const result = [];
    let rootConfig = {};
    let rootSchemas;
    let rootDocuments;
    let rootExternalDocuments;
    const generates = {};
    const cache = createCache();
    // We need a simple string to uniqually identify the provided GraphQLSchema objects for the above cache.
    // Because JavaScript does not provide access to its internal object ids, we need a workaround.
    // Below is a common way to get unique ids for objects in JavaScript,
    // by using a WeakMap and autoincrementing the id.
    const jsObjectIds = new WeakMap();
    let jsObjectIdCounter = 0;
    function getJsObjectId(schema) {
        if (!jsObjectIds.has(schema)) {
            jsObjectIds.set(schema, jsObjectIdCounter++);
        }
        return jsObjectIds.get(schema);
    }
    function wrapTask(task, source, taskName, ctx) {
        return () => context.profiler.run(async () => {
            try {
                await Promise.resolve().then(() => task());
            }
            catch (error) {
                if (source && !(error instanceof graphql_1.GraphQLError)) {
                    error.source = source;
                }
                ctx.errors.push(error);
                throw error;
            }
        }, taskName);
    }
    async function normalize() {
        /* Load Require extensions */
        const requireExtensions = (0, plugin_helpers_1.normalizeInstanceOrArray)(config.require);
        const loader = makeDefaultLoader(context.cwd);
        for (const mod of requireExtensions) {
            await loader(mod);
        }
        /* Root plugin  config */
        rootConfig = config.config || {};
        /* Normalize root "schema" field */
        rootSchemas = (0, plugin_helpers_1.normalizeInstanceOrArray)(config.schema);
        /* Normalize root "documents" field */
        rootDocuments = (0, plugin_helpers_1.normalizeInstanceOrArray)(config.documents);
        /* Normalize root "externalDocuments" field */
        rootExternalDocuments = (0, plugin_helpers_1.normalizeInstanceOrArray)(config.externalDocuments);
        /* Normalize "generators" field */
        const generateKeys = Object.keys(config.generates || {});
        if (generateKeys.length === 0) {
            throw new Error(`Invalid Codegen Configuration! \n
        Please make sure that your codegen config file contains the "generates" field, with a specification for the plugins you need.

        It should looks like that:

        schema:
          - my-schema.graphql
        generates:
          my-file.ts:
            - plugin1
            - plugin2
            - plugin3`);
        }
        for (const filename of generateKeys) {
            const output = (generates[filename] = (0, plugin_helpers_1.normalizeOutputParam)(config.generates[filename]));
            if (!output.preset && (!output.plugins || output.plugins.length === 0)) {
                throw new Error(`Invalid Codegen Configuration! \n
          Please make sure that your codegen config file has defined plugins list for output "${filename}".

          It should looks like that:

          schema:
            - my-schema.graphql
          generates:
            my-file.ts:
              - plugin1
              - plugin2
              - plugin3
          `);
            }
        }
        if (rootSchemas.length === 0 &&
            Object.keys(generates).some(filename => !generates[filename].schema ||
                (Array.isArray(generates[filename].schema === 'object') &&
                    generates[filename].schema.length === 0))) {
            throw new Error(`Invalid Codegen Configuration! \n
        Please make sure that your codegen config file contains either the "schema" field
        or every generated file has its own "schema" field.

        It should looks like that:
        schema:
          - my-schema.graphql

        or:
        generates:
          path/to/output:
            schema: my-schema.graphql
      `);
        }
    }
    const isTest = process.env.NODE_ENV === 'test';
    const tasks = new listr2_1.Listr([
        {
            title: 'Parse Configuration',
            task: () => normalize(),
        },
        {
            title: 'Generate outputs',
            task: (ctx, task) => {
                const generateTasks = Object.keys(generates).map(filename => {
                    const outputConfig = generates[filename];
                    const hasPreset = !!outputConfig.preset;
                    const title = `Generate to ${filename}`;
                    return {
                        title,
                        async task(_, subTask) {
                            let outputSchemaAst;
                            let outputSchema;
                            const outputFileTemplateConfig = outputConfig.config || {};
                            const outputDocuments = [];
                            const outputSpecificSchemas = (0, plugin_helpers_1.normalizeInstanceOrArray)(outputConfig.schema);
                            let outputSpecificDocuments = (0, plugin_helpers_1.normalizeInstanceOrArray)(outputConfig.documents);
                            let outputSpecificExternalDocuments = (0, plugin_helpers_1.normalizeInstanceOrArray)(outputConfig.externalDocuments);
                            const preset = hasPreset
                                ? typeof outputConfig.preset === 'string'
                                    ? await (0, presets_js_1.getPresetByName)(outputConfig.preset, makeDefaultLoader(context.cwd))
                                    : outputConfig.preset
                                : null;
                            if (preset?.prepareDocuments) {
                                outputSpecificDocuments = await preset.prepareDocuments(filename, outputSpecificDocuments);
                                outputSpecificExternalDocuments = await preset.prepareDocuments(filename, outputSpecificExternalDocuments);
                            }
                            return subTask.newListr([
                                {
                                    title: 'Load GraphQL schemas',
                                    task: wrapTask(async () => {
                                        (0, debugging_js_1.debugLog)(`[CLI] Loading Schemas`);
                                        const schemaPointerMap = {};
                                        const parsedSchemas = [];
                                        const allSchemaDenormalizedPointers = [
                                            ...rootSchemas,
                                            ...outputSpecificSchemas,
                                        ];
                                        for (const denormalizedPtr of allSchemaDenormalizedPointers) {
                                            if ((0, graphql_1.isSchema)(denormalizedPtr)) {
                                                parsedSchemas.push(denormalizedPtr);
                                            }
                                            else if (typeof denormalizedPtr === 'string') {
                                                schemaPointerMap[denormalizedPtr] = {};
                                            }
                                            else if (typeof denormalizedPtr === 'object') {
                                                Object.assign(schemaPointerMap, denormalizedPtr);
                                            }
                                        }
                                        const hash = JSON.stringify(schemaPointerMap) +
                                            parsedSchemas.map(getJsObjectId).join(',');
                                        const result = await cache('schema', hash, async () => {
                                            // collect parsed schemas
                                            const schemasToMerge = [...parsedSchemas];
                                            // collect schemas, provided by pointers
                                            if (Object.keys(schemaPointerMap).length) {
                                                schemasToMerge.push(await context.loadSchema(schemaPointerMap));
                                            }
                                            // merge all collected schemas into one
                                            const outputSchemaAst = schemasToMerge.length === 1
                                                ? schemasToMerge[0]
                                                : (0, graphql_1.buildASTSchema)((0, merge_1.mergeTypeDefs)(schemasToMerge));
                                            const outputSchema = (0, plugin_helpers_1.getCachedDocumentNodeFromSchema)(outputSchemaAst);
                                            return {
                                                outputSchemaAst,
                                                outputSchema,
                                            };
                                        });
                                        outputSchemaAst = result.outputSchemaAst;
                                        outputSchema = result.outputSchema;
                                    }, filename, `Load GraphQL schemas: ${filename}`, ctx),
                                },
                                {
                                    title: 'Load GraphQL documents',
                                    task: wrapTask(async () => {
                                        (0, debugging_js_1.debugLog)(`[CLI] Loading Documents`);
                                        const populateDocumentPointerMap = (allDocumentsDenormalizedPointers) => {
                                            const pointer = {};
                                            for (const denormalizedPtr of allDocumentsDenormalizedPointers) {
                                                if (typeof denormalizedPtr === 'string') {
                                                    pointer[denormalizedPtr] = {};
                                                }
                                                else if (typeof denormalizedPtr === 'object') {
                                                    Object.assign(pointer, denormalizedPtr);
                                                }
                                            }
                                            return pointer;
                                        };
                                        const allDocumentsDenormalizedPointers = [
                                            ...rootDocuments,
                                            ...outputSpecificDocuments,
                                        ];
                                        const documentPointerMap = populateDocumentPointerMap(allDocumentsDenormalizedPointers);
                                        const hash = JSON.stringify(documentPointerMap);
                                        const outputDocumentsStandard = await cache('documents', hash, async () => {
                                            try {
                                                const documents = await context.loadDocuments(documentPointerMap, 'standard');
                                                return documents;
                                            }
                                            catch (error) {
                                                if (error instanceof load_1.NoTypeDefinitionsFound &&
                                                    config.ignoreNoDocuments) {
                                                    return [];
                                                }
                                                throw error;
                                            }
                                        });
                                        const allExternalDocumentsDenormalizedPointers = [
                                            ...rootExternalDocuments,
                                            ...outputSpecificExternalDocuments,
                                        ];
                                        const externalDocumentsPointerMap = populateDocumentPointerMap(allExternalDocumentsDenormalizedPointers);
                                        const externalDocumentHash = JSON.stringify(externalDocumentsPointerMap);
                                        const outputExternalDocuments = await cache('documents', externalDocumentHash, async () => {
                                            try {
                                                const documents = await context.loadDocuments(externalDocumentsPointerMap, 'external');
                                                return documents;
                                            }
                                            catch (error) {
                                                if (error instanceof load_1.NoTypeDefinitionsFound &&
                                                    config.ignoreNoDocuments) {
                                                    return [];
                                                }
                                                throw error;
                                            }
                                        });
                                        /**
                                         * Merging `standard` and `external` documents here,
                                         * so they can be processed the same way,
                                         * before passed into presets and plugins
                                         */
                                        const processedFile = {};
                                        const mergedDocuments = [
                                            ...outputDocumentsStandard,
                                            ...outputExternalDocuments,
                                        ];
                                        for (const file of mergedDocuments) {
                                            const fileIdentifier = (file.location || '') + (file.hash || '');
                                            if (processedFile[fileIdentifier]) {
                                                continue;
                                            }
                                            outputDocuments.push(file);
                                            processedFile[fileIdentifier] = true;
                                        }
                                    }, filename, `Load GraphQL documents: ${filename}`, ctx),
                                },
                                {
                                    title: 'Generate',
                                    task: wrapTask(async () => {
                                        (0, debugging_js_1.debugLog)(`[CLI] Generating output`);
                                        const normalizedPluginsArray = (0, plugin_helpers_1.normalizeConfig)(outputConfig.plugins);
                                        const pluginLoader = config.pluginLoader || makeDefaultLoader(context.cwd);
                                        const pluginPackages = await Promise.all(normalizedPluginsArray.map(plugin => (0, plugins_js_1.getPluginByName)(Object.keys(plugin)[0], pluginLoader)));
                                        const pluginMap = Object.fromEntries(pluginPackages.map((pkg, i) => {
                                            const plugin = normalizedPluginsArray[i];
                                            const name = Object.keys(plugin)[0];
                                            return [name, pkg];
                                        }));
                                        const rawMergedConfig = {
                                            ...rootConfig,
                                            emitLegacyCommonJSImports: config.emitLegacyCommonJSImports,
                                            importExtension: config.importExtension,
                                            ...(typeof outputFileTemplateConfig === 'string'
                                                ? { value: outputFileTemplateConfig }
                                                : outputFileTemplateConfig),
                                        };
                                        const importExtension = (0, plugin_helpers_1.normalizeImportExtension)({
                                            emitLegacyCommonJSImports: rawMergedConfig.emitLegacyCommonJSImports,
                                            importExtension: rawMergedConfig.importExtension,
                                        });
                                        const mergedConfig = {
                                            ...rawMergedConfig,
                                            importExtension,
                                            emitLegacyCommonJSImports: rawMergedConfig.emitLegacyCommonJSImports ?? true,
                                        };
                                        const documentTransforms = Array.isArray(outputConfig.documentTransforms)
                                            ? await Promise.all(outputConfig.documentTransforms.map(async (config, index) => {
                                                return await (0, documentTransforms_js_1.getDocumentTransform)(config, makeDefaultLoader(context.cwd), `the element at index ${index} of the documentTransforms`);
                                            }))
                                            : [];
                                        const outputs = preset
                                            ? await context.profiler.run(async () => preset.buildGeneratesSection({
                                                baseOutputDir: filename,
                                                presetConfig: outputConfig.presetConfig || {},
                                                plugins: normalizedPluginsArray,
                                                schema: outputSchema,
                                                schemaAst: outputSchemaAst,
                                                documents: outputDocuments,
                                                config: mergedConfig,
                                                pluginMap,
                                                pluginContext,
                                                profiler: context.profiler,
                                                documentTransforms,
                                            }), `Build Generates Section: ${filename}`)
                                            : [
                                                {
                                                    filename,
                                                    plugins: normalizedPluginsArray,
                                                    schema: outputSchema,
                                                    schemaAst: outputSchemaAst,
                                                    documents: outputDocuments,
                                                    config: mergedConfig,
                                                    pluginMap,
                                                    pluginContext,
                                                    profiler: context.profiler,
                                                    documentTransforms,
                                                },
                                            ];
                                        const process = async (outputArgs) => {
                                            const output = await (0, core_1.codegen)({
                                                ...outputArgs,
                                                importExtension,
                                                emitLegacyCommonJSImports: rawMergedConfig.emitLegacyCommonJSImports ?? true,
                                                cache,
                                            });
                                            result.push({
                                                filename: outputArgs.filename,
                                                content: output,
                                                hooks: outputConfig.hooks || {},
                                            });
                                        };
                                        await context.profiler.run(() => Promise.all(outputs.map(process)), `Codegen: ${filename}`);
                                    }, filename, `Generate: ${filename}`, ctx),
                                },
                            ], {
                                /**
                                 * For each `generates` task, we must do the following in order:
                                 *
                                 * 1. Load schema
                                 * 2. Load documents
                                 * 3. Generate based on the schema + documents
                                 *
                                 * This way, the 3rd step has all the schema and documents loaded in previous steps to work correctly
                                 */
                                exitOnError: true,
                                concurrent: false,
                            });
                        },
                        // It doesn't stop when one of tasks failed, to finish at least some of outputs
                        exitOnError: false,
                    };
                });
                return task.newListr(generateTasks, {
                    concurrent: (0, os_1.cpus)().length || 1,
                });
            },
        },
    ], {
        rendererOptions: {
            clearOutput: false,
            collapseSubtasks: true,
            formatOutput: 'wrap',
            removeEmptyLines: false,
        },
        renderer: config.verbose ? 'verbose' : 'default',
        ctx: { errors: [] },
        silentRendererCondition: isTest || config.silent,
        exitOnError: true,
    });
    // All the errors throw in `listr2` are collected in context
    // Running tasks doesn't throw anything
    const executedContext = await tasks.run();
    if (config.debug) {
        // if we have debug logs, make sure to print them before throwing the errors
        (0, debugging_js_1.printLogs)();
    }
    let error = null;
    if (executedContext.errors.length > 0) {
        const errors = executedContext.errors.map(subErr => subErr.message || subErr.toString());
        error = new AggregateError(executedContext.errors, String(errors.join('\n\n')));
        // Best-effort to all stack traces for debugging
        error.stack = `${error.stack}\n\n${executedContext.errors
            .map(subErr => subErr.stack)
            .join('\n\n')}`;
    }
    return { result, error };
}
