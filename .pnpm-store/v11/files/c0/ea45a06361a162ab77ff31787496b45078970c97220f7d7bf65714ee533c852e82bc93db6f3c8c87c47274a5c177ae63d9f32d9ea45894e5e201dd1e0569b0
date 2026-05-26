"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sortPatterns = exports.makeLocalPatternSet = exports.makeGlobalPatternSet = exports.makeShouldRebuild = exports.allAffirmativePatternsFromPatternSets = void 0;
const tslib_1 = require("tslib");
const path_1 = require("path");
const is_glob_1 = tslib_1.__importDefault(require("is-glob"));
const micromatch_1 = tslib_1.__importDefault(require("micromatch"));
const plugin_helpers_1 = require("@graphql-codegen/plugin-helpers");
const utils_1 = require("@graphql-tools/utils");
const helpers_js_1 = require("./helpers.js");
/**
 * Flatten a list of pattern sets to be a list of only the affirmative patterns
 * are contained in all of them.
 *
 * This can be used, for example, to find the "longest common prefix directory"
 * by examining `mm.scan(pattern).base` for each `pattern`.
 */
const allAffirmativePatternsFromPatternSets = (patternSets) => {
    return patternSets.flatMap(patternSet => [
        ...patternSet.watch.affirmative,
        ...patternSet.documents.affirmative,
        ...patternSet.schemas.affirmative,
    ]);
};
exports.allAffirmativePatternsFromPatternSets = allAffirmativePatternsFromPatternSets;
/**
 * Create a rebuild trigger that follows the algorithm described here:
 * https://github.com/dotansimha/graphql-code-generator/issues/9270#issuecomment-1496765045
 *
 * There is a flow chart diagram in that comment.
 *
 * Basically:
 *
 *  * "Global" patterns are defined at top level of config file, and "local"
 *    patterns are defined for each output target
 *  * Each pattern can have "watch", "documents", and "schemas"
 *  * Watch patterns (global and local) always take precedence over documents and
 *    schemas patterns, i.e. a watch negation always negates, and a watch match is
 *    a match even if it would be negated by some pattern in documents or schemas
 *  * The trigger returns true if any output target's local patterns result in
 *    a match, after considering the precedence of any global and local negations
 */
const makeShouldRebuild = ({ globalPatternSet, localPatternSets, }) => {
    const localMatchers = localPatternSets.map(localPatternSet => {
        return (path) => {
            // Is path negated by any negating watch pattern?
            if (matchesAnyNegatedPattern(path, [
                ...globalPatternSet.watch.negated,
                ...localPatternSet.watch.negated,
            ])) {
                // Short circut: negations in watch patterns take priority
                return false;
            }
            // Does path match any affirmative watch pattern?
            if (matchesAnyAffirmativePattern(path, [
                ...globalPatternSet.watch.affirmative,
                ...localPatternSet.watch.affirmative,
            ])) {
                // Immediately return true: Watch pattern takes priority, even if documents or schema would negate it
                return true;
            }
            // Does path match documents patterns (without being negated)?
            if (matchesAnyAffirmativePattern(path, [
                ...globalPatternSet.documents.affirmative,
                ...localPatternSet.documents.affirmative,
            ]) &&
                !matchesAnyNegatedPattern(path, [
                    ...globalPatternSet.documents.negated,
                    ...localPatternSet.documents.negated,
                ])) {
                return true;
            }
            // Does path match schemas patterns (without being negated)?
            if (matchesAnyAffirmativePattern(path, [
                ...globalPatternSet.schemas.affirmative,
                ...localPatternSet.schemas.affirmative,
            ]) &&
                !matchesAnyNegatedPattern(path, [
                    ...globalPatternSet.schemas.negated,
                    ...localPatternSet.schemas.negated,
                ])) {
                return true;
            }
            // Otherwise, there is no match
            return false;
        };
    });
    /**
     * Return `true` if `path` should trigger a rebuild
     */
    return ({ path: absolutePath }) => {
        if (!(0, path_1.isAbsolute)(absolutePath)) {
            throw new Error('shouldRebuild trigger should be called with absolute path');
        }
        const path = (0, path_1.relative)(process.cwd(), absolutePath);
        const shouldRebuild = localMatchers.some(matcher => matcher(path));
        return shouldRebuild;
    };
};
exports.makeShouldRebuild = makeShouldRebuild;
/**
 * Create the pattern set for the "global" (top level) config.
 *
 * In the `shouldRebuild` algorithm, any of these watch patterns will take
 * precedence over local configs, and any schemas and documents patterns will be
 * mixed into the pattern set of each local config.
 */
const makeGlobalPatternSet = (initialContext) => {
    const config = initialContext.getConfig();
    return {
        watch: (0, exports.sortPatterns)([
            ...(typeof config.watch === 'boolean'
                ? []
                : (0, plugin_helpers_1.normalizeInstanceOrArray)(config.watch ?? [])),
            (0, path_1.relative)(process.cwd(), initialContext.filepath),
        ]),
        schemas: (0, exports.sortPatterns)(makePatternsFromSchemas((0, plugin_helpers_1.normalizeInstanceOrArray)(config.schema))),
        documents: (0, exports.sortPatterns)(makePatternsFromDocuments((0, plugin_helpers_1.normalizeInstanceOrArray)(config.documents))),
    };
};
exports.makeGlobalPatternSet = makeGlobalPatternSet;
/**
 * Create the pattern set for a "local" (output target) config
 *
 * In the `shouldRebuild` algorithm, any of these watch patterns will take
 * precedence over documents or schemas patterns, and the documents and schemas
 * patterns will be mixed into the pattern set of their respective gobal pattern
 * set equivalents.
 */
const makeLocalPatternSet = (conf) => {
    return {
        watch: (0, exports.sortPatterns)((0, plugin_helpers_1.normalizeInstanceOrArray)(conf.watchPattern)),
        documents: (0, exports.sortPatterns)(makePatternsFromDocuments((0, plugin_helpers_1.normalizeInstanceOrArray)(conf.documents))),
        schemas: (0, exports.sortPatterns)(makePatternsFromSchemas((0, plugin_helpers_1.normalizeInstanceOrArray)(conf.schema))),
    };
};
exports.makeLocalPatternSet = makeLocalPatternSet;
/**
 * Parse a list of micromatch patterns from a list of documents, which should
 * already have been normalized from their raw config values.
 */
const makePatternsFromDocuments = (documents) => {
    const patterns = [];
    if (documents) {
        for (const doc of documents) {
            if (typeof doc === 'string') {
                patterns.push(doc);
            }
            else {
                patterns.push(...Object.keys(doc));
            }
        }
    }
    return patterns;
};
/**
 * Parse a list of micromatch patterns from a list of schemas, which should
 * already have been normalized from their raw config values.
 */
const makePatternsFromSchemas = (schemas) => {
    const patterns = [];
    for (const s of schemas) {
        const schema = s;
        if (!(0, helpers_js_1.isURL)(schema) && ((0, is_glob_1.default)(schema) || (0, utils_1.isValidPath)(schema))) {
            patterns.push(schema);
        }
    }
    return patterns;
};
/**
 * Given a list of micromatch patterns, sort them into `patterns` (all of them),
 * `affirmative` (only the affirmative patterns), and `negated` (only the negated patterns)
 *
 * @param patterns List of micromatch patterns
 */
const sortPatterns = (patterns) => ({
    patterns,
    affirmative: onlyAffirmativePatterns(patterns),
    negated: onlyNegatedPatterns(patterns),
});
exports.sortPatterns = sortPatterns;
/**
 * Filter the provided list of patterns to include only "affirmative" (non-negated) patterns.
 *
 * @param patterns List of micromatch patterns (or paths) to filter
 */
const onlyAffirmativePatterns = (patterns) => {
    return patterns.filter(pattern => !micromatch_1.default.scan(pattern).negated);
};
/**
 * Filter the provided list of patterns to include only negated patterns.
 *
 * @param patterns List of micromatch patterns (or paths) to filter
 */
const onlyNegatedPatterns = (patterns) => {
    return patterns.filter(pattern => micromatch_1.default.scan(pattern).negated);
};
/**
 * Given a list of negated patterns, invert them by removing their negation prefix
 *
 * If there is a non-negated pattern in the list, throw an error, because this
 * function should only be called after filtering the list to be only negated patterns
 *
 * @param patterns List of negated micromatch patterns
 */
const invertNegatedPatterns = (patterns) => {
    return patterns.map(pattern => {
        const scanned = micromatch_1.default.scan(pattern);
        if (!scanned.negated) {
            throw new Error(`onlyNegatedPatterns got a non-negated pattern: ${pattern}`);
        }
        // Remove the leading prefix (NOTE: this is not always "!")
        // e.g. mm.scan("!./foo/bar/never-watch.graphql").prefix === '!./'
        return pattern.slice(scanned.prefix.length);
    });
};
/**
 * Return true if relativeCandidatePath matches any of the affirmativePatterns
 *
 * @param relativeCandidatePath A relative path to evaluate against the supplied affirmativePatterns
 * @param affirmativePatterns A list of patterns, containing no negated patterns, to evaluate
 */
const matchesAnyAffirmativePattern = (relativeCandidatePath, affirmativePatterns) => {
    if ((0, path_1.isAbsolute)(relativeCandidatePath)) {
        throw new Error('matchesAny should only be called with relative candidate path');
    }
    // Developer error: This function is not intended to work with pattern sets including negations
    if (affirmativePatterns.some(pattern => micromatch_1.default.scan(pattern).negated)) {
        throw new Error('matchesAnyAffirmativePattern should only include affirmative patterns');
    }
    // micromatch.isMatch does not omit matches that are negated by negation patterns,
    // which is why we require this function only examine affirmative patterns
    return micromatch_1.default.isMatch(relativeCandidatePath, affirmativePatterns);
};
/**
 * Return true if relativeCandidatePath matches any of the negatedPatterns
 *
 * This function will invert the negated patterns and then call matchesAnyAffirmativePattern
 *
 * @param relativeCandidatePath A relative path to evaluate against the suppliednegatedPatterns
 * @param negatedPatterns A list of patterns, containing no negated patterns, to evaluate
 */
const matchesAnyNegatedPattern = (relativeCandidatePath, negatedPatterns) => {
    // NOTE: No safety check that negatedPatterns contains only negated, because that will happen in invertedNegatedPatterns
    return matchesAnyAffirmativePattern(relativeCandidatePath, invertNegatedPatterns(negatedPatterns));
};
