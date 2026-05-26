"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.transformDocuments = transformDocuments;
const plugin_helpers_1 = require("@graphql-codegen/plugin-helpers");
async function transformDocuments(options) {
    const documentTransforms = options.documentTransforms || [];
    let documents = options.documents;
    if (documentTransforms.length === 0 || options.documents.length === 0) {
        return documents;
    }
    const profiler = options.profiler ?? (0, plugin_helpers_1.createNoopProfiler)();
    for (const documentTransform of documentTransforms) {
        const config = typeof documentTransform.config === 'object'
            ? {
                ...options.config,
                ...documentTransform.config,
            }
            : {};
        const { transform } = documentTransform.transformObject;
        if (transform && typeof transform === 'function') {
            const name = documentTransform.name;
            try {
                await profiler.run(async () => {
                    documents = await transform({
                        documents,
                        schema: options.schema,
                        config,
                        pluginContext: options.pluginContext,
                    });
                }, `DocumentTransform "${name}" execution`);
            }
            catch (e) {
                throw new Error(`DocumentTransform "${name}" failed: \n
            ${e.message}
          `);
            }
        }
        else {
            throw new Error(`Missing 'transform' function in "${documentTransform.name}"`);
        }
    }
    return documents;
}
