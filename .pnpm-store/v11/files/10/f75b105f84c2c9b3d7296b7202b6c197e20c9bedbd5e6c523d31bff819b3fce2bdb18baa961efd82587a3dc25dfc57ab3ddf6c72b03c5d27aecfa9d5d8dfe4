import { DefinitionNode, DocumentNode, NameNode } from 'graphql';
export type VisitedFilesMap = Map<string, Map<string, Set<DefinitionNode>>>;
/**
 * Configuration for path aliasing in GraphQL import statements using the same
 * syntax as tsconfig.json#paths
 */
export interface PathAliases {
    /**
     * Root directory for resolving relative paths in mappings. Defaults to the
     * current working directory.
     *
     * @example
     * ```ts
     * {
     *   rootDir: '/project/src/graphql',
     *   mappings: {
     *     '@types': './types' // Will resolve to '/project/src/graphql/types'
     *   }
     * }
     * ```
     */
    rootDir?: string;
    /**
     * A map of path aliases to their corresponding file system paths. Keys are
     * the aliases used in import statements, values are the paths they resolve
     * to.
     *
     * ## Supports two patterns:
     *
     * 1. Exact mapping: Maps a specific alias to a specific file
     *    `'@user': '/path/to/user.graphql'`
     *
     * 2. Wildcard mapping: Maps a prefix pattern to a directory pattern using '*'
     *    2a. The '*' is replaced with the remainder of the import path
     *        `'@models/*': '/path/to/models/*'`
     *    2b. Maps to a directory without wildcard expansion
     *        `'@types/*': '/path/to/types'`
     *
     * @example
     * ```ts
     * {
     *   mappings: {
     *     // Exact mapping
     *     '@schema': '/project/schema/main.graphql',
     *
     *     // Wildcard mapping with expansion
     *     '@models/*': '/project/graphql/models/*',
     *
     *     // Wildcard mapping without expansion
     *     '@types/*': '/project/graphql/types.graphql',
     *
     *     // Relative paths (resolved against rootDir if specified)
     *     '@common': './common/types.graphql'
     *   }
     * }
     * ```
     *
     * Import examples:
     * - `#import User from "@schema"` → `/project/schema/main.graphql`
     * - `#import User from "@models/user.graphql"` → `/project/graphql/models/user.graphql`
     * - `#import User from "@types/user.graphql"` → `/project/graphql/types.graphql`
     * - `#import User from "@common"` → Resolved relative to rootDir
     */
    mappings: Record<string, string>;
}
/**
 * Loads the GraphQL document and recursively resolves all the imports
 * and copies them into the final document.
 * processImport does not merge the typeDefs as designed ( https://github.com/ardatan/graphql-tools/issues/2980#issuecomment-1003692728 )
 */
export declare function processImport(filePath: string, cwd?: string, predefinedImports?: Record<string, string>, visitedFiles?: VisitedFilesMap, pathAliases?: PathAliases): DocumentNode;
type DependencySet = Map<string, Set<NameNode>>;
type DependenciesByDefinitionName = Map<string, DependencySet>;
export declare function extractDependencies(filePath: string, fileContents: string): {
    definitionsByName: Map<string, Set<DefinitionNode>>;
    dependenciesByDefinitionName: DependenciesByDefinitionName;
};
export declare function processImports(importLines: string[], filePath: string, visitedFiles: VisitedFilesMap, predefinedImports: Record<string, string>, pathAliases?: PathAliases): {
    allImportedDefinitionsMap: Map<string, Set<DefinitionNode>>;
    potentialTransitiveDefinitionsMap: Map<string, Set<DefinitionNode>>;
};
/**
 * Splits the contents of a GraphQL file into lines that are imports
 * and other lines which define the actual GraphQL document.
 */
export declare function extractImportLines(fileContent: string): {
    importLines: string[];
    otherLines: string;
};
/**
 * Parses an import line, returning a list of entities imported and the file
 * from which they are imported.
 *
 * Throws if the import line does not have a correct format.
 */
export declare function parseImportLine(importLine: string): {
    imports: string[];
    from: string;
};
export {};
