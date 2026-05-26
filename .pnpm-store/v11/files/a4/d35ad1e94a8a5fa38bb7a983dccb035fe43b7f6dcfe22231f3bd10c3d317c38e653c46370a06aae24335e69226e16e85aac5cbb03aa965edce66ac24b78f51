import { Source } from 'graphql';
import { ExpressionStatement, TemplateLiteral } from '@babel/types';
import { PluckedContent } from './visitor.cjs';
/**
 * Additional options for determining how a file is parsed.
 */
export interface GraphQLTagPluckOptions {
    /**
     * Additional options for determining how a file is parsed. An array of packages that are responsible for exporting the GraphQL string parser function. The following modules are supported by default:
     * ```js
     * {
     *   modules: [
     *     {
     *       // import gql from 'graphql-tag'
     *       name: 'graphql-tag',
     *     },
     *     {
     *       name: 'graphql-tag.macro',
     *     },
     *     {
     *       // import { graphql } from 'gatsby'
     *       name: 'gatsby',
     *       identifier: 'graphql',
     *     },
     *     {
     *       name: 'apollo-server-express',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: 'apollo-server',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: 'react-relay',
     *       identifier: 'graphql',
     *     },
     *     {
     *       name: 'apollo-boost',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: 'apollo-server-koa',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: 'apollo-server-hapi',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: 'apollo-server-fastify',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: ' apollo-server-lambda',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: 'apollo-server-micro',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: 'apollo-server-azure-functions',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: 'apollo-server-cloud-functions',
     *       identifier: 'gql',
     *     },
     *     {
     *       name: 'apollo-server-cloudflare',
     *       identifier: 'gql',
     *     },
     *   ];
     * }
     * ```
     */
    modules?: Array<{
        name: string;
        identifier?: string;
    }>;
    /**
     * The magic comment anchor to look for when parsing GraphQL strings. Defaults to `graphql`.
     */
    gqlMagicComment?: string;
    /**
     * The name of a custom Vue block that contains raw GraphQL to be plucked.
     */
    gqlVueBlock?: string;
    /**
     * Allows to use a global identifier instead of a module import.
     * ```js
     * // `graphql` is a global function
     * export const usersQuery = graphql`
     *   {
     *     users {
     *       id
     *       name
     *     }
     *   }
     * `;
     * ```
     */
    globalGqlIdentifierName?: string | string[];
    /**
     * Set to `true` in order to get the found documents as-is, without any changes indentation changes
     */
    skipIndent?: boolean;
    /**
     * A function that allows custom extraction of GraphQL strings from a file.
     */
    pluckStringFromFile?: (code: string, node: TemplateLiteral, options: Omit<GraphQLTagPluckOptions, 'isGqlTemplateLiteral' | 'pluckStringFromFile'>) => string | undefined | null;
    /**
     * A custom way to determine if a template literal node contains a GraphQL query.
     * By default, it checks if the leading comment is equal to the `gqlMagicComment` option.
     */
    isGqlTemplateLiteral?: (node: TemplateLiteral | ExpressionStatement, options: Omit<GraphQLTagPluckOptions, 'isGqlTemplateLiteral' | 'pluckStringFromFile'>) => boolean | undefined;
}
/**
 * Asynchronously plucks GraphQL template literals from a single file.
 *
 * Supported file extensions include: `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`, `.cts`, `.tsx`, `.flow`, `.flow.js`, `.flow.jsx`, `.vue`, `.svelte`, `.astro`
 *
 * @param filePath Path to the file containing the code. Required to detect the file type
 * @param code The contents of the file being parsed.
 * @param options Additional options for determining how a file is parsed.
 */
export declare const gqlPluckFromCodeString: (filePath: string, code: string, options?: GraphQLTagPluckOptions) => Promise<Source[]>;
/**
 * Synchronously plucks GraphQL template literals from a single file
 *
 * Supported file extensions include: `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mjs`, `.cjs`, `.tsx`, `.flow`, `.flow.js`, `.flow.jsx`, `.vue`, `.svelte`, `.astro`, `.gts`, `.gjs`
 *
 * @param filePath Path to the file containing the code. Required to detect the file type
 * @param code The contents of the file being parsed.
 * @param options Additional options for determining how a file is parsed.
 */
export declare const gqlPluckFromCodeStringSync: (filePath: string, code: string, options?: GraphQLTagPluckOptions) => Source[];
export declare function parseCode({ code, filePath, options, }: {
    code: string;
    filePath: string;
    options: GraphQLTagPluckOptions;
}): PluckedContent[];
