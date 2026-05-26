import { Types } from '@graphql-codegen/plugin-helpers';
import { CodegenContext } from '../config.js';
type NegatedPattern = `!${string}`;
/**
 * Flatten a list of pattern sets to be a list of only the affirmative patterns
 * are contained in all of them.
 *
 * This can be used, for example, to find the "longest common prefix directory"
 * by examining `mm.scan(pattern).base` for each `pattern`.
 */
export declare const allAffirmativePatternsFromPatternSets: (patternSets: PatternSet[]) => string[];
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
export declare const makeShouldRebuild: ({ globalPatternSet, localPatternSets, }: {
    globalPatternSet: PatternSet;
    localPatternSets: PatternSet[];
}) => ({ path: absolutePath }: {
    path: string;
}) => boolean;
/**
 * Create the pattern set for the "global" (top level) config.
 *
 * In the `shouldRebuild` algorithm, any of these watch patterns will take
 * precedence over local configs, and any schemas and documents patterns will be
 * mixed into the pattern set of each local config.
 */
export declare const makeGlobalPatternSet: (initialContext: CodegenContext) => {
    watch: SortedPatterns<string>;
    schemas: SortedPatterns<string>;
    documents: SortedPatterns<string>;
};
/**
 * Create the pattern set for a "local" (output target) config
 *
 * In the `shouldRebuild` algorithm, any of these watch patterns will take
 * precedence over documents or schemas patterns, and the documents and schemas
 * patterns will be mixed into the pattern set of their respective gobal pattern
 * set equivalents.
 */
export declare const makeLocalPatternSet: (conf: Types.ConfiguredOutput) => {
    watch: SortedPatterns<string>;
    documents: SortedPatterns<string>;
    schemas: SortedPatterns<string>;
};
/**
 * Given a list of micromatch patterns, sort them into `patterns` (all of them),
 * `affirmative` (only the affirmative patterns), and `negated` (only the negated patterns)
 *
 * @param patterns List of micromatch patterns
 */
export declare const sortPatterns: <P extends string | NegatedPattern>(patterns: P[]) => SortedPatterns<P>;
/**
 * A type that "sorts" (or "groups") patterns. For a given list of `patterns`,
 * this type will include the original list in `patterns`, all of its
 * "affirmative" (non-negated) patterns in `affirmative`, and all of its
 * "negated" patterns in `negated`
 */
type SortedPatterns<PP extends string | NegatedPattern = string | NegatedPattern> = {
    /** List of patterns, which could include both negated and affirmative patterns */
    patterns: PP[];
    /** List of only the affirmative (non-negated) patterns in `patterns` */
    affirmative: PP[];
    /** List of only the negated patterns in `patterns` */
    negated: Extract<PP, NegatedPattern>[];
};
/**
 * The global (top-level) config and each local (output target) config can have
 * patterns which are separable into "watch" (always takes precedence), "documents",
 * and "schemas". This type can hold sorted versions of these patterns.
 */
type PatternSet = {
    watch: SortedPatterns;
    documents: SortedPatterns;
    schemas: SortedPatterns;
};
export {};
