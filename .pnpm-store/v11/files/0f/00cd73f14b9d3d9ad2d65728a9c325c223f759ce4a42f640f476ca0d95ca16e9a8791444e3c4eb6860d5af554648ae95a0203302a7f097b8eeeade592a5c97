/**
 * Exposes a simple and efficient API for interacting with Federation V2's `@link` directives
 * according to spec.
 */
import type { DocumentNode } from 'graphql';
import { FederatedLink } from './link.cjs';
export declare const FEDERATION_V1: unique symbol;
export type LinkVersion = string | {
    major: number;
    minor: number;
} | null | typeof FEDERATION_V1;
/**
 * This function is for power users who want to develop their own Federation 2 `@link` feature(s).
 * It enables you to define and support multiple versions of the feature and to easily reference the named imports.
 * This includes official federation features if you choose to implement them yourself.
 *
 * @example
 *
 * GraphQL SDL:
 *   extend schema \@link(url: "https://specs.graphql-hive.com/example/v1.0", import: ["@example"])
 *
 *
 * Code:
 *   import { extractLinkImplementations } from '@theguild/federation-composition';
 *   const { matchesImplementation, resolveImportName } = extractLinkImplementations(typeDefs);
 *
 *   if (matchesImplementation('https://specs.graphql-hive.com/example', 'v1.0')) {
 *     const examples: Record<string, string> = {}
 *     const exampleName = resolveImportName('https://specs.graphql-hive.com/example', '@example');
 *     visit(typeDefs, {
 *       FieldDefinition: node => {
 *         const example = node.directives?.find(d => d.name.value === exampleName)
 *         if (example) {
 *           examples[node.name.value] = (
 *             example.arguments?.find(a => a.name.value === 'eg')?.value as
 *               | StringValueNode
 *               | undefined
 *           )?.value
 *         }
 *       }
 *     });
 *   }
 */
export declare function extractLinkImplementations(typeDefs: DocumentNode): {
    links: FederatedLink[];
    /**
     *
     * @param identity The link identity. E.g. https://specs.apollo.dev/link/v1.0
     * @param name The imported object name, without namespacing. E.g. "@link"
     * @returns The imported object's name within the typedefs. E.g.
     *   For `@link(url: "https://example.com/", import: [{ name: "@example", as: "@eg" }])`,
     *   `resolveImportName("@example")` returns "eg".
     *   And for `@link(url: "https://example.com/foo")`, `resolveImportName("@example")`
     *   returns the namespaced name, "foo__example"
     */
    resolveImportName: (identity: string, name: string) => string;
    /**
     * Check that the linked version is supported by the code implementation.
     *
     * @param identity The link identity. E.g. https://specs.graphql-hive.com/example
     * @param version The version in which the feature was added. E.g. 1.0
     * @returns true if the supplied link supports this the version argument.
     *   E.g. matchesImplementation('https://specs.graphql-hive.com/example', '1.1') returns true if
     *   is version >= 1.1 < 2.0, but false if the link is version 1.0
     */
    matchesImplementation: (identity: string, version: LinkVersion) => boolean;
};
