import { debugTimerEnd, debugTimerStart, parseGraphQLSDL, printSchemaWithDirectives, printWithComments, resetComments, } from '@graphql-tools/utils';
import { filterKind } from '../filter-document-kind.js';
export function parseSource({ partialSource, options, pointerOptionMap, addValidSource, }) {
    if (partialSource) {
        debugTimerStart(`@graphql-tools/load: parseSource ${partialSource.location}`);
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
        debugTimerEnd(`@graphql-tools/load: parseSource ${partialSource.location}`);
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
        debugTimerStart(`@graphql-tools/load: parseSchema ${input.source.location}`);
        input.source.rawSDL = printSchemaWithDirectives(input.source.schema, input.options);
        debugTimerEnd(`@graphql-tools/load: parseSchema ${input.source.location}`);
    }
}
function parseRawSDL(input) {
    if (input.source.rawSDL) {
        debugTimerStart(`@graphql-tools/load: parseRawSDL ${input.source.location}`);
        input.source.document = parseGraphQLSDL(input.source.location, input.source.rawSDL, input.options).document;
        debugTimerEnd(`@graphql-tools/load: parseRawSDL ${input.source.location}`);
    }
}
function useKindsFilter(input) {
    if (input.options.filterKinds) {
        debugTimerStart(`@graphql-tools/load: useKindsFilter ${input.source.location}`);
        input.source.document = filterKind(input.source.document, input.options.filterKinds);
        debugTimerEnd(`@graphql-tools/load: useKindsFilter ${input.source.location}`);
    }
}
function useComments(input) {
    if (!input.source.rawSDL && input.source.document) {
        debugTimerStart(`@graphql-tools/load: useComments ${input.source.location}`);
        input.source.rawSDL = printWithComments(input.source.document);
        resetComments();
        debugTimerEnd(`@graphql-tools/load: useComments ${input.source.location}`);
    }
}
function collectValidSources(input, addValidSource) {
    if (input.source.document?.definitions && input.source.document.definitions.length > 0) {
        debugTimerStart(`@graphql-tools/load: collectValidSources ${input.source.location}`);
        addValidSource(input.source);
        debugTimerEnd(`@graphql-tools/load: collectValidSources ${input.source.location}`);
    }
}
