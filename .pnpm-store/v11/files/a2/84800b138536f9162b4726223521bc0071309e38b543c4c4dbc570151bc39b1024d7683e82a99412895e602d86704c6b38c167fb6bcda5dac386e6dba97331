"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.processImport = processImport;
exports.extractDependencies = extractDependencies;
exports.processImports = processImports;
exports.extractImportLines = extractImportLines;
exports.parseImportLine = parseImportLine;
const tslib_1 = require("tslib");
const fs_1 = require("fs");
const path_1 = require("path");
const graphql_1 = require("graphql");
const resolve_from_1 = tslib_1.__importDefault(require("resolve-from"));
const utils_1 = require("@graphql-tools/utils");
const index_js_1 = require("./link/index.js");
const builtinTypes = ['String', 'Float', 'Int', 'Boolean', 'ID', 'Upload'];
const federationV1Directives = ['key', 'provides', 'requires', 'external'];
const builtinDirectives = [
    'deprecated',
    'skip',
    'include',
    'cacheControl',
    'connection',
    'client',
    'specifiedBy',
    'oneOf',
    ...federationV1Directives,
];
const IMPORT_FROM_REGEX = /^import\s+(\*|(.*))\s+from\s+('|")(.*)('|");?$/;
const IMPORT_DEFAULT_REGEX = /^import\s+('|")(.*)('|");?$/;
/**
 * Loads the GraphQL document and recursively resolves all the imports
 * and copies them into the final document.
 * processImport does not merge the typeDefs as designed ( https://github.com/ardatan/graphql-tools/issues/2980#issuecomment-1003692728 )
 */
function processImport(filePath, cwd = globalThis.process?.cwd(), predefinedImports = {}, visitedFiles = new Map(), pathAliases) {
    const set = visitFile(filePath, (0, path_1.join)(cwd + '/root.graphql'), visitedFiles, predefinedImports, pathAliases);
    const definitionStrSet = new Set();
    let definitionsStr = '';
    for (const defs of set.values()) {
        for (const def of defs) {
            const defStr = (0, graphql_1.print)(def);
            if (!definitionStrSet.has(defStr)) {
                definitionStrSet.add(defStr);
                definitionsStr += defStr + '\n';
            }
        }
    }
    return definitionsStr?.length
        ? (0, graphql_1.parse)(new graphql_1.Source(definitionsStr, filePath))
        : {
            kind: graphql_1.Kind.DOCUMENT,
            definitions: [],
        };
}
function visitFile(filePath, cwd, visitedFiles, predefinedImports, pathAliases) {
    if (!(filePath in predefinedImports)) {
        filePath = applyPathAliases(filePath, pathAliases);
        if (!(0, path_1.isAbsolute)(filePath)) {
            filePath = resolveFilePath(cwd, filePath);
        }
    }
    if (!visitedFiles.has(filePath)) {
        const fileContent = filePath in predefinedImports ? predefinedImports[filePath] : (0, fs_1.readFileSync)(filePath, 'utf8');
        const { importLines, otherLines } = extractImportLines(fileContent);
        const { definitionsByName, dependenciesByDefinitionName } = extractDependencies(filePath, otherLines);
        const fileDefinitionMap = getFileDefinitionMap(definitionsByName, dependenciesByDefinitionName);
        // To prevent circular dependency
        visitedFiles.set(filePath, fileDefinitionMap);
        const { allImportedDefinitionsMap, potentialTransitiveDefinitionsMap } = processImports(importLines, filePath, visitedFiles, predefinedImports, pathAliases);
        const addDefinition = (definition, definitionName, definitionSet) => {
            const fileDefinitionMap = visitedFiles.get(filePath);
            if (fileDefinitionMap && !definitionSet.has(definition)) {
                definitionSet.add(definition);
                // Call addDefinition recursively to add all dependent documents
                if ('name' in definition && definition.name) {
                    const documentName = definition.name.value;
                    const dependencyDefinitionForDocument = allImportedDefinitionsMap.get(documentName);
                    dependencyDefinitionForDocument?.forEach(node => {
                        if (node !== definition) {
                            addDefinition(node, definitionName, definitionSet);
                        }
                    });
                }
                // Regenerate field exports if some fields are imported after visitor
                if ('fields' in definition && definition.fields) {
                    for (const field of definition.fields) {
                        const fieldName = field.name.value;
                        const fieldDefinitionName = definition.name.value + '.' + fieldName;
                        const allImportedDefinitions = allImportedDefinitionsMap.get(definitionName);
                        allImportedDefinitions?.forEach(importedDefinition => {
                            if (!fileDefinitionMap.has(fieldDefinitionName)) {
                                fileDefinitionMap.set(fieldDefinitionName, new Set());
                            }
                            const definitionsWithDeps = fileDefinitionMap.get(fieldDefinitionName);
                            if (definitionsWithDeps) {
                                addDefinition(importedDefinition, fieldDefinitionName, definitionsWithDeps);
                            }
                        });
                        const newDependencySet = new Map();
                        switch (field.kind) {
                            case graphql_1.Kind.FIELD_DEFINITION:
                                visitFieldDefinitionNode(field, newDependencySet, dependenciesByDefinitionName);
                                break;
                            case graphql_1.Kind.INPUT_VALUE_DEFINITION:
                                visitInputValueDefinitionNode(field, newDependencySet, dependenciesByDefinitionName);
                                break;
                        }
                        Array.from(newDependencySet.keys()).forEach(dependencyName => {
                            const definitionsInCurrentFile = fileDefinitionMap.get(dependencyName);
                            definitionsInCurrentFile?.forEach(def => addDefinition(def, definitionName, definitionSet));
                            const definitionsFromImports = allImportedDefinitionsMap.get(dependencyName);
                            definitionsFromImports?.forEach(def => addDefinition(def, definitionName, definitionSet));
                            const transitiveDependencies = potentialTransitiveDefinitionsMap.get(dependencyName);
                            transitiveDependencies?.forEach(def => addDefinition(def, definitionName, definitionSet));
                        });
                    }
                }
            }
        };
        if (!otherLines) {
            visitedFiles.set(filePath, allImportedDefinitionsMap);
        }
        else {
            const fileDefinitionMap = visitedFiles.get(filePath);
            if (fileDefinitionMap) {
                for (const [definitionName] of definitionsByName) {
                    const definitionsWithDependencies = fileDefinitionMap.get(definitionName);
                    if (definitionsWithDependencies) {
                        const allImportedDefinitions = allImportedDefinitionsMap.get(definitionName);
                        allImportedDefinitions?.forEach(importedDefinition => {
                            addDefinition(importedDefinition, definitionName, definitionsWithDependencies);
                        });
                        const dependenciesOfDefinition = dependenciesByDefinitionName.get(definitionName);
                        if (dependenciesOfDefinition) {
                            for (const [dependencyName, dependencyNodes] of dependenciesOfDefinition.entries()) {
                                // If that dependency cannot be found both in imports and this file, throw an error
                                if (!allImportedDefinitionsMap.has(dependencyName) &&
                                    !definitionsByName.has(dependencyName)) {
                                    throw (0, utils_1.createGraphQLError)(`Couldn't find type ${dependencyName} in any of the schemas.`, { nodes: Array.from(dependencyNodes) });
                                }
                                const dependencyDefinitionsFromImports = allImportedDefinitionsMap.get(dependencyName);
                                dependencyDefinitionsFromImports?.forEach(dependencyDefinition => {
                                    // addDefinition will add recursively all dependent documents for dependencyName document
                                    if ('name' in dependencyDefinition &&
                                        dependencyDefinition.name &&
                                        dependencyDefinition.name.value === dependencyName) {
                                        addDefinition(dependencyDefinition, definitionName, definitionsWithDependencies);
                                    }
                                });
                            }
                        }
                    }
                }
            }
        }
    }
    return visitedFiles.get(filePath);
}
function extractDependencies(filePath, fileContents) {
    const definitionsByName = new Map();
    const dependenciesByDefinitionName = new Map();
    const { document } = (0, utils_1.parseGraphQLSDL)(filePath, fileContents);
    for (const definition of document.definitions) {
        visitDefinition(definition, definitionsByName, dependenciesByDefinitionName);
    }
    return {
        definitionsByName,
        dependenciesByDefinitionName,
    };
}
function importFederatedSchemaLinks(definition, definitionsByName) {
    const addDefinition = (name) => {
        definitionsByName.set(name.replace(/^@/g, ''), new Set());
    };
    // extract links from this definition
    const { links, matchesImplementation, resolveImportName } = (0, index_js_1.extractLinkImplementations)({
        kind: graphql_1.Kind.DOCUMENT,
        definitions: [definition],
    });
    if (links.length) {
        const federationUrl = 'https://specs.apollo.dev/federation';
        const linkUrl = 'https://specs.apollo.dev/link';
        /**
         * Official Federated imports are special because they can be referenced without specifyin the import.
         * To handle this case, we must prepare a list of all the possible valid usages to check against.
         * Note that this versioning is not technically correct, since some definitions are after v2.0.
         * But this is enough information to be comfortable not blocking the imports at this phase. It's
         * the job of the composer to validate the versions.
         * */
        if (matchesImplementation(federationUrl, 'v2.0')) {
            const federationImports = [
                '@extends',
                '@external',
                '@inaccessible',
                '@key',
                '@override',
                '@provides',
                '@requires',
                '@shareable',
                '@tag',
                'FieldSet',
                /** v2.1 */
                '@composeDirective',
                /** v2.3 */
                '@interfaceObject',
                /** v2.5 */
                '@authenticated',
                '@requiresScopes',
                /** v2.6 */
                '@policy',
                /** v2.8 */
                '@context',
                '@fromContext',
                /** v2.9 */
                '@cost',
                '@listSize',
                /** v2.10 */
                '@connect',
                '@source',
            ];
            for (const i of federationImports) {
                addDefinition(resolveImportName(federationUrl, i));
            }
        }
        if (matchesImplementation(linkUrl, 'v1.0')) {
            const linkImports = ['Purpose', 'Import', '@link'];
            for (const i of linkImports) {
                addDefinition(resolveImportName(linkUrl, i));
            }
        }
        const imported = links
            .filter(l => ![linkUrl, federationUrl].includes(l.identity))
            .flatMap(l => l.imports.map(i => i.as ?? i.name));
        for (const namedImport of imported) {
            addDefinition(namedImport);
        }
    }
}
function visitDefinition(definition, definitionsByName, dependenciesByDefinitionName) {
    // TODO: handle queries without names
    if ('name' in definition ||
        definition.kind === graphql_1.Kind.SCHEMA_DEFINITION ||
        definition.kind === graphql_1.Kind.SCHEMA_EXTENSION) {
        const definitionName = 'name' in definition && definition.name ? definition.name.value : 'schema';
        if (!definitionsByName.has(definitionName)) {
            definitionsByName.set(definitionName, new Set());
        }
        const definitionsSet = definitionsByName.get(definitionName);
        definitionsSet.add(definition);
        let dependencySet = dependenciesByDefinitionName.get(definitionName);
        if (!dependencySet) {
            dependencySet = new Map();
            dependenciesByDefinitionName.set(definitionName, dependencySet);
        }
        switch (definition.kind) {
            case graphql_1.Kind.OPERATION_DEFINITION:
                visitOperationDefinitionNode(definition, dependencySet);
                break;
            case graphql_1.Kind.FRAGMENT_DEFINITION:
                visitFragmentDefinitionNode(definition, dependencySet);
                break;
            case graphql_1.Kind.OBJECT_TYPE_DEFINITION:
                visitObjectTypeDefinitionNode(definition, dependencySet, dependenciesByDefinitionName);
                break;
            case graphql_1.Kind.INTERFACE_TYPE_DEFINITION:
                visitInterfaceTypeDefinitionNode(definition, dependencySet, dependenciesByDefinitionName);
                break;
            case graphql_1.Kind.UNION_TYPE_DEFINITION:
                visitUnionTypeDefinitionNode(definition, dependencySet);
                break;
            case graphql_1.Kind.ENUM_TYPE_DEFINITION:
                visitEnumTypeDefinitionNode(definition, dependencySet);
                break;
            case graphql_1.Kind.INPUT_OBJECT_TYPE_DEFINITION:
                visitInputObjectTypeDefinitionNode(definition, dependencySet, dependenciesByDefinitionName);
                break;
            case graphql_1.Kind.DIRECTIVE_DEFINITION:
                visitDirectiveDefinitionNode(definition, dependencySet, dependenciesByDefinitionName);
                break;
            case graphql_1.Kind.SCALAR_TYPE_DEFINITION:
                visitScalarDefinitionNode(definition, dependencySet);
                break;
            case graphql_1.Kind.SCHEMA_DEFINITION:
                importFederatedSchemaLinks(definition, definitionsByName);
                visitSchemaDefinitionNode(definition, dependencySet);
                break;
            case graphql_1.Kind.SCHEMA_EXTENSION:
                importFederatedSchemaLinks(definition, definitionsByName);
                visitSchemaExtensionDefinitionNode(definition, dependencySet);
                break;
            case graphql_1.Kind.OBJECT_TYPE_EXTENSION:
                visitObjectTypeExtensionNode(definition, dependencySet, dependenciesByDefinitionName);
                break;
            case graphql_1.Kind.INTERFACE_TYPE_EXTENSION:
                visitInterfaceTypeExtensionNode(definition, dependencySet, dependenciesByDefinitionName);
                break;
            case graphql_1.Kind.UNION_TYPE_EXTENSION:
                visitUnionTypeExtensionNode(definition, dependencySet);
                break;
            case graphql_1.Kind.ENUM_TYPE_EXTENSION:
                visitEnumTypeExtensionNode(definition, dependencySet);
                break;
            case graphql_1.Kind.INPUT_OBJECT_TYPE_EXTENSION:
                visitInputObjectTypeExtensionNode(definition, dependencySet, dependenciesByDefinitionName);
                break;
            case graphql_1.Kind.SCALAR_TYPE_EXTENSION:
                visitScalarExtensionNode(definition, dependencySet);
                break;
        }
        if ('fields' in definition && definition.fields) {
            for (const field of definition.fields) {
                const definitionName = definition.name.value + '.' + field.name.value;
                if (!definitionsByName.has(definitionName)) {
                    definitionsByName.set(definitionName, new Set());
                }
                definitionsByName.get(definitionName)?.add({
                    ...definition,
                    fields: [field],
                });
                let dependencySet = dependenciesByDefinitionName.get(definitionName);
                if (!dependencySet) {
                    dependencySet = new Map();
                    dependenciesByDefinitionName.set(definitionName, dependencySet);
                }
                switch (field.kind) {
                    case graphql_1.Kind.FIELD_DEFINITION:
                        visitFieldDefinitionNode(field, dependencySet, dependenciesByDefinitionName);
                        break;
                    case graphql_1.Kind.INPUT_VALUE_DEFINITION:
                        visitInputValueDefinitionNode(field, dependencySet, dependenciesByDefinitionName);
                        break;
                }
            }
        }
    }
}
function getFileDefinitionMap(definitionsByName, dependenciesByDefinitionName) {
    const fileDefinitionMap = new Map();
    for (const [definitionName, definitions] of definitionsByName) {
        let definitionsWithDependencies = fileDefinitionMap.get(definitionName);
        if (definitionsWithDependencies == null) {
            definitionsWithDependencies = new Set();
            fileDefinitionMap.set(definitionName, definitionsWithDependencies);
        }
        for (const definition of definitions) {
            definitionsWithDependencies.add(definition);
        }
        const dependenciesOfDefinition = dependenciesByDefinitionName.get(definitionName);
        if (dependenciesOfDefinition) {
            for (const dependencyName of dependenciesOfDefinition.keys()) {
                const dependencyDefinitions = definitionsByName.get(dependencyName);
                if (dependencyDefinitions != null) {
                    for (const dependencyDefinition of dependencyDefinitions) {
                        definitionsWithDependencies.add(dependencyDefinition);
                    }
                }
            }
        }
    }
    return fileDefinitionMap;
}
function processImports(importLines, filePath, visitedFiles, predefinedImports, pathAliases) {
    const potentialTransitiveDefinitionsMap = new Map();
    const allImportedDefinitionsMap = new Map();
    for (const line of importLines) {
        const { imports, from } = parseImportLine(line.replace('#', '').trim());
        const importFileDefinitionMap = visitFile(from, filePath, visitedFiles, predefinedImports, pathAliases);
        const buildFullDefinitionMap = (dependenciesMap) => {
            for (const [importedDefinitionName, importedDefinitions] of importFileDefinitionMap) {
                const [importedDefinitionTypeName] = importedDefinitionName.split('.');
                if (!dependenciesMap.has(importedDefinitionTypeName)) {
                    dependenciesMap.set(importedDefinitionTypeName, new Set());
                }
                const allImportedDefinitions = dependenciesMap.get(importedDefinitionTypeName);
                if (allImportedDefinitions) {
                    for (const importedDefinition of importedDefinitions) {
                        allImportedDefinitions.add(importedDefinition);
                    }
                }
            }
        };
        buildFullDefinitionMap(potentialTransitiveDefinitionsMap);
        if (imports.includes('*')) {
            buildFullDefinitionMap(allImportedDefinitionsMap);
        }
        else {
            for (let importedDefinitionName of imports) {
                if (importedDefinitionName.endsWith('.*')) {
                    // Adding whole type means the same thing with adding every single field
                    importedDefinitionName = importedDefinitionName.replace('.*', '');
                }
                const [importedDefinitionTypeName] = importedDefinitionName.split('.');
                if (!allImportedDefinitionsMap.has(importedDefinitionTypeName)) {
                    allImportedDefinitionsMap.set(importedDefinitionTypeName, new Set());
                }
                const allImportedDefinitions = allImportedDefinitionsMap.get(importedDefinitionTypeName);
                const importedDefinitions = importFileDefinitionMap.get(importedDefinitionName);
                if (!importedDefinitions) {
                    throw new Error(`${importedDefinitionName} is not exported by ${from} imported by ${filePath}`);
                }
                if (allImportedDefinitions != null) {
                    for (const importedDefinition of importedDefinitions) {
                        allImportedDefinitions.add(importedDefinition);
                    }
                }
            }
        }
    }
    return { allImportedDefinitionsMap, potentialTransitiveDefinitionsMap };
}
/**
 * Splits the contents of a GraphQL file into lines that are imports
 * and other lines which define the actual GraphQL document.
 */
function extractImportLines(fileContent) {
    const importLines = [];
    let otherLines = '';
    for (const line of fileContent.split('\n')) {
        const trimmedLine = line.trim();
        if (trimmedLine.startsWith('#import ') || trimmedLine.startsWith('# import ')) {
            importLines.push(trimmedLine);
        }
        else if (trimmedLine) {
            otherLines += line + '\n';
        }
    }
    return { importLines, otherLines };
}
/**
 * Parses an import line, returning a list of entities imported and the file
 * from which they are imported.
 *
 * Throws if the import line does not have a correct format.
 */
function parseImportLine(importLine) {
    let regexMatch = importLine.match(IMPORT_FROM_REGEX);
    if (regexMatch != null) {
        // Apply regex to import line
        // Extract matches into named variables
        const [, wildcard, importsString, , from] = regexMatch;
        if (from) {
            // Extract imported types
            const imports = wildcard === '*' ? ['*'] : importsString.split(',').map(d => d.trim());
            // Return information about the import line
            return { imports, from };
        }
    }
    regexMatch = importLine.match(IMPORT_DEFAULT_REGEX);
    if (regexMatch != null) {
        const [, , from] = regexMatch;
        if (from) {
            return { imports: ['*'], from };
        }
    }
    throw new Error(`
    Import statement is not valid:
    > ${importLine}
    If you want to have comments starting with '# import', please use ''' instead!
    You can only have 'import' statements in the following pattern;
    # import [Type].[Field] from [File]
  `);
}
function resolveFilePath(filePath, importFrom) {
    const dirName = (0, path_1.dirname)(filePath);
    try {
        const fullPath = (0, path_1.join)(dirName, importFrom);
        return (0, fs_1.realpathSync)(fullPath);
    }
    catch (e) {
        if (e.code === 'ENOENT') {
            return (0, resolve_from_1.default)(dirName, importFrom);
        }
        throw e;
    }
}
/**
 * Rewrites the provided file path using the first matched path alias (or
 * returns the file path with no changes if none match).
 *
 * @param filePath - The file path to rewrite.
 * @param pathAliases - The path aliases to evaluate.
 *
 * @returns The rewritten file path.
 */
function applyPathAliases(filePath, pathAliases) {
    if (pathAliases == null) {
        return filePath;
    }
    for (const [prefixPattern, mapping] of Object.entries(pathAliases.mappings)) {
        const matchedMapping = applyPathAlias(prefixPattern, mapping, filePath);
        if (matchedMapping == null) {
            continue;
        }
        const resolvedMapping = (0, resolve_from_1.default)(pathAliases.rootDir ?? process.cwd(), matchedMapping);
        return (0, fs_1.realpathSync)(resolvedMapping);
    }
    return filePath;
}
/**
 * Resolves an import alias and it's mapping using the same strategy as
 * tsconfig.json#paths
 *
 * @param prefixPattern - The import alias pattern.
 * @param mapping - The mapping applied if the prefixPattern matches.
 * @param importFrom - The import to evaluate.
 *
 * @returns The mapped import or null if the alias did not match.
 *
 * @see https://www.typescriptlang.org/tsconfig/#paths
 */
function applyPathAlias(prefixPattern, mapping, importFrom) {
    if (prefixPattern.endsWith('*')) {
        const prefix = prefixPattern.slice(0, -1);
        if (!importFrom.startsWith(prefix)) {
            return null;
        }
        const remainder = importFrom.slice(prefix.length);
        if (mapping.endsWith('*')) {
            return mapping.slice(0, -1) + remainder;
        }
        return mapping;
    }
    if (importFrom !== prefixPattern) {
        return null;
    }
    if (mapping.endsWith('*')) {
        return mapping.slice(0, -1);
    }
    return mapping;
}
function addToDependencySet(dependencySet, node) {
    const existingNodes = dependencySet.get(node.value);
    if (existingNodes != null) {
        existingNodes.add(node);
        return;
    }
    dependencySet.set(node.value, new Set([node]));
}
function visitOperationDefinitionNode(node, dependencySet) {
    if (node.name?.value) {
        addToDependencySet(dependencySet, node.name);
    }
    node.selectionSet.selections.forEach(selectionNode => visitSelectionNode(selectionNode, dependencySet));
}
function visitSelectionNode(node, dependencySet) {
    switch (node.kind) {
        case graphql_1.Kind.FIELD:
            visitFieldNode(node, dependencySet);
            break;
        case graphql_1.Kind.FRAGMENT_SPREAD:
            visitFragmentSpreadNode(node, dependencySet);
            break;
        case graphql_1.Kind.INLINE_FRAGMENT:
            visitInlineFragmentNode(node, dependencySet);
            break;
    }
}
function visitFieldNode(node, dependencySet) {
    node.selectionSet?.selections.forEach(selectionNode => visitSelectionNode(selectionNode, dependencySet));
}
function visitFragmentSpreadNode(node, dependencySet) {
    addToDependencySet(dependencySet, node.name);
}
function visitInlineFragmentNode(node, dependencySet) {
    node.selectionSet.selections.forEach(selectionNode => visitSelectionNode(selectionNode, dependencySet));
}
function visitFragmentDefinitionNode(node, dependencySet) {
    addToDependencySet(dependencySet, node.name);
    node.selectionSet.selections.forEach(selectionNode => visitSelectionNode(selectionNode, dependencySet));
}
function addInterfaceDependencies(node, dependencySet, dependenciesByDefinitionName) {
    // all interfaces should be dependent to each other
    const allDependencies = [
        node.name,
        ...(node.interfaces?.map((namedTypeNode) => namedTypeNode.name) || []),
    ];
    node.interfaces?.forEach((namedTypeNode) => {
        visitNamedTypeNode(namedTypeNode, dependencySet);
        const interfaceName = namedTypeNode.name.value;
        let set = dependenciesByDefinitionName.get(interfaceName);
        // interface should be dependent to the type as well
        if (set == null) {
            set = new Map();
            dependenciesByDefinitionName.set(interfaceName, set);
        }
        allDependencies.forEach(dependency => {
            if (dependency.value !== interfaceName) {
                addToDependencySet(set, dependency);
            }
        });
    });
}
function visitObjectTypeDefinitionNode(node, dependencySet, dependenciesByDefinitionName) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.fields?.forEach(fieldDefinitionNode => visitFieldDefinitionNode(fieldDefinitionNode, dependencySet, dependenciesByDefinitionName));
    addInterfaceDependencies(node, dependencySet, dependenciesByDefinitionName);
}
function visitDirectiveNode(node, dependencySet) {
    const directiveName = node.name.value;
    if (!builtinDirectives.includes(directiveName)) {
        addToDependencySet(dependencySet, node.name);
    }
}
function visitFieldDefinitionNode(node, dependencySet, dependenciesByDefinitionName) {
    node.arguments?.forEach(inputValueDefinitionNode => visitInputValueDefinitionNode(inputValueDefinitionNode, dependencySet, dependenciesByDefinitionName));
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    visitTypeNode(node.type, dependencySet, dependenciesByDefinitionName);
}
function visitTypeNode(node, dependencySet, dependenciesByDefinitionName) {
    switch (node.kind) {
        case graphql_1.Kind.LIST_TYPE:
            visitListTypeNode(node, dependencySet, dependenciesByDefinitionName);
            break;
        case graphql_1.Kind.NON_NULL_TYPE:
            visitNonNullTypeNode(node, dependencySet, dependenciesByDefinitionName);
            break;
        case graphql_1.Kind.NAMED_TYPE:
            visitNamedTypeNode(node, dependencySet);
            break;
    }
}
function visitListTypeNode(node, dependencySet, dependenciesByDefinitionName) {
    visitTypeNode(node.type, dependencySet, dependenciesByDefinitionName);
}
function visitNonNullTypeNode(node, dependencySet, dependenciesByDefinitionName) {
    visitTypeNode(node.type, dependencySet, dependenciesByDefinitionName);
}
function visitNamedTypeNode(node, dependencySet) {
    const namedTypeName = node.name.value;
    if (!builtinTypes.includes(namedTypeName)) {
        addToDependencySet(dependencySet, node.name);
    }
}
function visitInputValueDefinitionNode(node, dependencySet, dependenciesByDefinitionName) {
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    visitTypeNode(node.type, dependencySet, dependenciesByDefinitionName);
}
function visitInterfaceTypeDefinitionNode(node, dependencySet, dependenciesByDefinitionName) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.fields?.forEach(fieldDefinitionNode => visitFieldDefinitionNode(fieldDefinitionNode, dependencySet, dependenciesByDefinitionName));
    addInterfaceDependencies(node, dependencySet, dependenciesByDefinitionName);
}
function visitUnionTypeDefinitionNode(node, dependencySet) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.types?.forEach(namedTypeNode => visitNamedTypeNode(namedTypeNode, dependencySet));
}
function visitEnumTypeDefinitionNode(node, dependencySet) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
}
function visitInputObjectTypeDefinitionNode(node, dependencySet, dependenciesByDefinitionName) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.fields?.forEach(inputValueDefinitionNode => visitInputValueDefinitionNode(inputValueDefinitionNode, dependencySet, dependenciesByDefinitionName));
}
function visitDirectiveDefinitionNode(node, dependencySet, dependenciesByDefinitionName) {
    addToDependencySet(dependencySet, node.name);
    node.arguments?.forEach(inputValueDefinitionNode => visitInputValueDefinitionNode(inputValueDefinitionNode, dependencySet, dependenciesByDefinitionName));
}
function visitObjectTypeExtensionNode(node, dependencySet, dependenciesByDefinitionName) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.fields?.forEach(fieldDefinitionNode => visitFieldDefinitionNode(fieldDefinitionNode, dependencySet, dependenciesByDefinitionName));
    addInterfaceDependencies(node, dependencySet, dependenciesByDefinitionName);
}
function visitInterfaceTypeExtensionNode(node, dependencySet, dependenciesByDefinitionName) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.fields?.forEach(fieldDefinitionNode => visitFieldDefinitionNode(fieldDefinitionNode, dependencySet, dependenciesByDefinitionName));
    addInterfaceDependencies(node, dependencySet, dependenciesByDefinitionName);
}
function visitUnionTypeExtensionNode(node, dependencySet) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.types?.forEach(namedTypeNode => visitNamedTypeNode(namedTypeNode, dependencySet));
}
function visitEnumTypeExtensionNode(node, dependencySet) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
}
function visitInputObjectTypeExtensionNode(node, dependencySet, dependenciesByDefinitionName) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.fields?.forEach(inputValueDefinitionNode => visitInputValueDefinitionNode(inputValueDefinitionNode, dependencySet, dependenciesByDefinitionName));
}
function visitSchemaDefinitionNode(node, dependencySet) {
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.operationTypes.forEach(operationTypeDefinitionNode => visitOperationTypeDefinitionNode(operationTypeDefinitionNode, dependencySet));
}
function visitSchemaExtensionDefinitionNode(node, dependencySet) {
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
    node.operationTypes?.forEach(operationTypeDefinitionNode => visitOperationTypeDefinitionNode(operationTypeDefinitionNode, dependencySet));
}
function visitScalarDefinitionNode(node, dependencySet) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
}
function visitScalarExtensionNode(node, dependencySet) {
    addToDependencySet(dependencySet, node.name);
    node.directives?.forEach(directiveNode => visitDirectiveNode(directiveNode, dependencySet));
}
function visitOperationTypeDefinitionNode(node, dependencySet) {
    visitNamedTypeNode(node.type, dependencySet);
}
