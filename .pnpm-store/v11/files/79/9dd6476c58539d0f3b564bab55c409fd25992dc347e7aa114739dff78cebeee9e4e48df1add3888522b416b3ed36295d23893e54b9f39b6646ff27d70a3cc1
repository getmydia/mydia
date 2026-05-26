"use strict";
/**
 * Exposes a simple and efficient API for interacting with Federation V2's `@link` directives
 * according to spec.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.FEDERATION_V1 = void 0;
exports.extractLinkImplementations = extractLinkImplementations;
const link_js_1 = require("./link.js");
exports.FEDERATION_V1 = Symbol('Federation_V1');
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
function extractLinkImplementations(typeDefs) {
    const links = link_js_1.FederatedLink.fromTypedefs(typeDefs);
    const linkByIdentity = Object.fromEntries(links.map(l => [l.identity, l]));
    // Any schema with a `@link` directive present is considered federation 2
    // although according to federation docs, schemas require linking specifically
    // the federation 2.x spec. The reason for not being so picky is that supergraphs also
    // use @link, but do not necessarily link to the federation 2.x spec.
    // Check if any @link or @core features are used.
    const supportsFederationV2 = Object.keys(linkByIdentity).length > 0;
    return {
        links,
        resolveImportName: (identity, name) => {
            const matchingLink = linkByIdentity[identity];
            if (!matchingLink) {
                return name.startsWith('@') ? name.substring(1) : name;
            }
            return matchingLink.resolveImportName(name);
        },
        matchesImplementation: (identity, version) => {
            // Assume Federation 1 means there is no link or identity and so it
            // always matches _if_ the typedefs dont use link or core.
            if (version === exports.FEDERATION_V1) {
                return !supportsFederationV2;
            }
            const matchingLink = linkByIdentity[identity];
            if (!matchingLink) {
                return false;
            }
            if (typeof version === 'string') {
                return matchingLink.supports(version);
            }
            if (version === null) {
                return matchingLink.supports(version);
            }
            return matchingLink.supports(version.major, version.minor);
        },
    };
}
