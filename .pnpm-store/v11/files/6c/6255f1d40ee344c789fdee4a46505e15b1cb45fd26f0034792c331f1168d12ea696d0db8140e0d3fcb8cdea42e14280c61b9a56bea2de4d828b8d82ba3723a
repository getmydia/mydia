"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.parseSource = parseSource;
const utils_1 = require("@graphql-tools/utils");
const filter_document_kind_js_1 = require("../filter-document-kind.js");
function parseSource({ partialSource, options, pointerOptionMap, addValidSource, }) {
    if (partialSource) {
        (0, utils_1.debugTimerStart)(`@graphql-tools/load: parseSource ${partialSource.location}`);
        const input = prepareInput({
            source: partialSource,
            options,
            pointerOptionMap,
        });
        parseSchema(input);
        parseRawSDL(input);
        if (input.source.document) {
            useKindsFilter(input);
            useComments(input);
            collectValidSources(input, addValidSource);
        }
        (0, utils_1.debugTimerEnd)(`@graphql-tools/load: parseSource ${partialSource.location}`);
    }
}
//
function prepareInput({ source, options, pointerOptionMap, }) {
    let specificOptions = {
        ...options,
    };
    if (source.location) {
        specificOptions = {
            ...specificOptions,
            ...pointerOptionMap[source.location],
        };
    }
    return { source: { ...source }, options: specificOptions };
}
function parseSchema(input) {
    if (input.source.schema) {
        (0, utils_1.debugTimerStart)(`@graphql-tools/load: parseSchema ${input.source.location}`);
        input.source.rawSDL = (0, utils_1.printSchemaWithDirectives)(input.source.schema, input.options);
        (0, utils_1.debugTimerEnd)(`@graphql-tools/load: parseSchema ${input.source.location}`);
    }
}
function parseRawSDL(input) {
    if (input.source.rawSDL) {
        (0, utils_1.debugTimerStart)(`@graphql-tools/load: parseRawSDL ${input.source.location}`);
        input.source.document = (0, utils_1.parseGraphQLSDL)(input.source.location, input.source.rawSDL, input.options).document;
        (0, utils_1.debugTimerEnd)(`@graphql-tools/load: parseRawSDL ${input.source.location}`);
    }
}
function useKindsFilter(input) {
    if (input.options.filterKinds) {
        (0, utils_1.debugTimerStart)(`@graphql-tools/load: useKindsFilter ${input.source.location}`);
        input.source.document = (0, filter_document_kind_js_1.filterKind)(input.source.document, input.options.filterKinds);
        (0, utils_1.debugTimerEnd)(`@graphql-tools/load: useKindsFilter ${input.source.location}`);
    }
}
function useComments(input) {
    if (!input.source.rawSDL && input.source.document) {
        (0, utils_1.debugTimerStart)(`@graphql-tools/load: useComments ${input.source.location}`);
        input.source.rawSDL = (0, utils_1.printWithComments)(input.source.document);
        (0, utils_1.resetComments)();
        (0, utils_1.debugTimerEnd)(`@graphql-tools/load: useComments ${input.source.location}`);
    }
}
function collectValidSources(input, addValidSource) {
    if (input.source.document?.definitions && input.source.document.definitions.length > 0) {
        (0, utils_1.debugTimerStart)(`@graphql-tools/load: collectValidSources ${input.source.location}`);
        addValidSource(input.source);
        (0, utils_1.debugTimerEnd)(`@graphql-tools/load: collectValidSources ${input.source.location}`);
    }
}
