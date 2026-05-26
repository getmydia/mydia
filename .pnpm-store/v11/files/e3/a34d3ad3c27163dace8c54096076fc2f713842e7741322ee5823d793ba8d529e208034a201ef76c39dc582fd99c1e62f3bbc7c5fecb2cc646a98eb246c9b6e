"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.NoTypeDefinitionsFound = void 0;
exports.loadTypedefs = loadTypedefs;
exports.loadTypedefsSync = loadTypedefsSync;
const utils_1 = require("@graphql-tools/utils");
const collect_sources_js_1 = require("./load-typedefs/collect-sources.js");
const options_js_1 = require("./load-typedefs/options.js");
const parse_js_1 = require("./load-typedefs/parse.js");
const helpers_js_1 = require("./utils/helpers.js");
const pointers_js_1 = require("./utils/pointers.js");
const CONCURRENCY_LIMIT = 100;
/**
 * Asynchronously loads any GraphQL documents (i.e. executable documents like
 * operations and fragments as well as type system definitions) from the
 * provided pointers.
 * loadTypedefs does not merge the typeDefs when `#import` is used ( https://github.com/ardatan/graphql-tools/issues/2980#issuecomment-1003692728 )
 * @param pointerOrPointers Pointers to the sources to load the documents from
 * @param options Additional options
 */
async function loadTypedefs(pointerOrPointers, options) {
    (0, utils_1.debugTimerStart)('@graphql-tools/load: loadTypedefs');
    const { ignore, pointerOptionMap } = (0, pointers_js_1.normalizePointers)(pointerOrPointers);
    options.ignore = (0, utils_1.asArray)(options.ignore || []);
    options.ignore.push(...ignore);
    (0, options_js_1.applyDefaultOptions)(options);
    const sources = await (0, collect_sources_js_1.collectSources)({
        pointerOptionMap,
        options,
    });
    const validSources = [];
    // If we have few k of files it may be an issue
    const limit = (0, helpers_js_1.useLimit)(CONCURRENCY_LIMIT);
    await Promise.all(sources.map(partialSource => limit(() => (0, parse_js_1.parseSource)({
        partialSource,
        options,
        pointerOptionMap,
        addValidSource(source) {
            validSources.push(source);
        },
    }))));
    const result = prepareResult({ options, pointerOptionMap, validSources });
    (0, utils_1.debugTimerEnd)('@graphql-tools/load: loadTypedefs');
    return result;
}
/**
 * Synchronously loads any GraphQL documents (i.e. executable documents like
 * operations and fragments as well as type system definitions) from the
 * provided pointers.
 * @param pointerOrPointers Pointers to the sources to load the documents from
 * @param options Additional options
 */
function loadTypedefsSync(pointerOrPointers, options) {
    (0, utils_1.debugTimerStart)('@graphql-tools/load: loadTypedefsSync');
    const { ignore, pointerOptionMap } = (0, pointers_js_1.normalizePointers)(pointerOrPointers);
    options.ignore = (0, utils_1.asArray)(options.ignore || []).concat(ignore);
    (0, options_js_1.applyDefaultOptions)(options);
    const sources = (0, collect_sources_js_1.collectSourcesSync)({
        pointerOptionMap,
        options,
    });
    const validSources = [];
    for (const partialSource of sources) {
        (0, parse_js_1.parseSource)({
            partialSource,
            options,
            pointerOptionMap,
            addValidSource(source) {
                validSources.push(source);
            },
        });
    }
    const result = prepareResult({ options, pointerOptionMap, validSources });
    (0, utils_1.debugTimerEnd)('@graphql-tools/load: loadTypedefsSync');
    return result;
}
//
function prepareResult({ options, pointerOptionMap, validSources, }) {
    (0, utils_1.debugTimerStart)('@graphql-tools/load: prepareResult');
    const pointerList = Object.keys(pointerOptionMap);
    if (pointerList.length > 0 && validSources.length === 0) {
        throw new NoTypeDefinitionsFound(pointerList);
    }
    const sortedResult = options.sort
        ? validSources.sort((left, right) => (0, utils_1.compareStrings)(left.location, right.location))
        : validSources;
    (0, utils_1.debugTimerEnd)('@graphql-tools/load: prepareResult');
    return sortedResult;
}
class NoTypeDefinitionsFound extends Error {
    constructor(pointerList) {
        super(`
      Unable to find any GraphQL type definitions for the following pointers:
      ${pointerList.map(p => `
        - ${p}
        `)}`);
        this.name = 'NoTypeDefinitionsFound';
    }
}
exports.NoTypeDefinitionsFound = NoTypeDefinitionsFound;
