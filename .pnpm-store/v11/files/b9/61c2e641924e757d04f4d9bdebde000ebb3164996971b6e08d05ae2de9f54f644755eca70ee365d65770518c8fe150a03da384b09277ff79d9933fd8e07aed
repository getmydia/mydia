import { basename, extname } from 'path';
import autoBind from 'auto-bind';
import { pascalCase } from 'change-case-all';
import { DepGraph } from 'dependency-graph';
import { Kind, print, } from 'graphql';
import gqlTag from 'graphql-tag';
import { normalizeImportExtension, oldVisit } from '@graphql-codegen/plugin-helpers';
import { optimizeDocumentNode } from '@graphql-tools/optimize';
import { BaseVisitor } from './base-visitor.js';
import { generateFragmentImportStatement } from './imports.js';
import { buildScalarsFromConfig, flatten, getConfigValue, groupBy, unique } from './utils.js';
gqlTag.enableExperimentalFragmentVariables();
export var DocumentMode;
(function (DocumentMode) {
    DocumentMode["graphQLTag"] = "graphQLTag";
    DocumentMode["documentNode"] = "documentNode";
    DocumentMode["documentNodeImportFragments"] = "documentNodeImportFragments";
    DocumentMode["external"] = "external";
    DocumentMode["string"] = "string";
})(DocumentMode || (DocumentMode = {}));
const EXTENSIONS_TO_REMOVE = ['.ts', '.tsx', '.js', '.jsx'];
export class ClientSideBaseVisitor extends BaseVisitor {
    _schema;
    _collectedOperations = [];
    _documents = [];
    _additionalImports = [];
    _imports = new Set();
    _onExecutableDocumentNode;
    _omitDefinitions;
    _fragments;
    fragmentsGraph;
    constructor(_schema, fragments, rawConfig, additionalConfig, documents) {
        super(rawConfig, {
            scalars: buildScalarsFromConfig(_schema, rawConfig),
            dedupeOperationSuffix: getConfigValue(rawConfig.dedupeOperationSuffix, false),
            optimizeDocumentNode: getConfigValue(rawConfig.optimizeDocumentNode, true),
            omitOperationSuffix: getConfigValue(rawConfig.omitOperationSuffix, false),
            gqlImport: rawConfig.gqlImport || null,
            documentNodeImport: rawConfig.documentNodeImport || null,
            noExport: !!rawConfig.noExport,
            importOperationTypesFrom: getConfigValue(rawConfig.importOperationTypesFrom, null),
            operationResultSuffix: getConfigValue(rawConfig.operationResultSuffix, ''),
            documentVariablePrefix: getConfigValue(rawConfig.documentVariablePrefix, ''),
            documentVariableSuffix: getConfigValue(rawConfig.documentVariableSuffix, 'Document'),
            fragmentVariablePrefix: getConfigValue(rawConfig.fragmentVariablePrefix, ''),
            fragmentVariableSuffix: getConfigValue(rawConfig.fragmentVariableSuffix, 'FragmentDoc'),
            documentMode: getConfigValue(rawConfig.documentMode, DocumentMode.graphQLTag),
            importDocumentNodeExternallyFrom: getConfigValue(rawConfig.importDocumentNodeExternallyFrom, ''),
            pureMagicComment: getConfigValue(rawConfig.pureMagicComment, false),
            experimentalFragmentVariables: getConfigValue(rawConfig.experimentalFragmentVariables, false),
            ...additionalConfig,
        });
        this._schema = _schema;
        this._documents = documents;
        this._onExecutableDocumentNode = rawConfig.unstable_onExecutableDocumentNode;
        this._omitDefinitions = rawConfig.unstable_omitDefinitions;
        this._fragments = new Map(fragments.map(fragment => [fragment.name, fragment]));
        this.fragmentsGraph = this._getFragmentsGraph();
        autoBind(this);
    }
    _extractFragments(document, withNested = false) {
        if (!document) {
            return [];
        }
        const names = new Set();
        oldVisit(document, {
            enter: {
                FragmentSpread: (node) => {
                    names.add(node.name.value);
                    if (withNested) {
                        const foundFragment = this._fragments.get(node.name.value);
                        if (foundFragment) {
                            const childItems = this._extractFragments(foundFragment.node, true);
                            if (childItems && childItems.length > 0) {
                                for (const item of childItems) {
                                    names.add(item);
                                }
                            }
                        }
                    }
                },
            },
        });
        return Array.from(names);
    }
    _transformFragments(fragmentNames) {
        return fragmentNames.map(document => this.getFragmentVariableName(document));
    }
    _includeFragments(fragments) {
        if (fragments && fragments.length > 0) {
            if (this.config.documentMode === DocumentMode.documentNode ||
                this.config.documentMode === DocumentMode.string) {
                return Array.from(this._fragments.values())
                    .filter(f => fragments.includes(this.getFragmentVariableName(f.name)))
                    .map(fragment => print(fragment.node))
                    .join('\n');
            }
            if (this.config.documentMode === DocumentMode.documentNodeImportFragments) {
                return '';
            }
            return String(fragments.map(name => '${' + name + '}').join('\n'));
        }
        return '';
    }
    _prepareDocument(documentStr) {
        return documentStr;
    }
    _gql(node) {
        const includeNestedFragments = this.config.documentMode === DocumentMode.documentNode ||
            this.config.documentMode === DocumentMode.string;
        const fragmentNames = this._extractFragments(node, includeNestedFragments);
        const fragments = this._transformFragments(fragmentNames);
        const doc = this._prepareDocument(`
    ${print(node).split('\\').join('\\\\') /* Re-escape escaped values in GraphQL syntax */}
    ${this._includeFragments(fragments)}`);
        if (this.config.documentMode === DocumentMode.documentNode) {
            let gqlObj = gqlTag([doc]);
            if (this.config.optimizeDocumentNode) {
                gqlObj = optimizeDocumentNode(gqlObj);
            }
            return JSON.stringify(gqlObj);
        }
        if (this.config.documentMode === DocumentMode.documentNodeImportFragments) {
            const gqlObj = gqlTag([doc]);
            // We need to inline all fragments that are used in this document
            // Otherwise we might encounter the following issues:
            // 1. missing fragments
            // 2. duplicated fragments
            const fragmentDependencyNames = new Set(fragmentNames.map(name => this.fragmentsGraph.dependenciesOf(name)).flatMap(item => item));
            for (const fragmentName of fragmentNames) {
                fragmentDependencyNames.add(fragmentName);
            }
            const jsonStringify = (json) => JSON.stringify(json, (key, value) => (key === 'loc' ? undefined : value));
            let definitions = [...gqlObj.definitions];
            for (const fragmentName of fragmentDependencyNames) {
                definitions.push(this.fragmentsGraph.getNodeData(fragmentName).node);
            }
            if (this.config.optimizeDocumentNode) {
                definitions = [
                    ...optimizeDocumentNode({
                        kind: Kind.DOCUMENT,
                        definitions,
                    }).definitions,
                ];
            }
            let metaString = '';
            if (this._onExecutableDocumentNode) {
                const meta = this._getGraphQLCodegenMetadata(node, definitions);
                if (meta) {
                    if (this._omitDefinitions === true) {
                        return `{${`"__meta__":${JSON.stringify(meta)},`.slice(0, -1)}}`;
                    }
                    metaString = `"__meta__":${JSON.stringify(meta)},`;
                }
            }
            return `{${metaString}"kind":"${Kind.DOCUMENT}","definitions":${jsonStringify(definitions)}}`;
        }
        if (this.config.documentMode === DocumentMode.string) {
            if (node.kind === Kind.FRAGMENT_DEFINITION) {
                const meta = this._getGraphQLCodegenMetadata(node, gqlTag([doc]).definitions);
                return `new TypedDocumentString(\`${doc}\`, ${JSON.stringify({
                    fragmentName: node.name.value,
                    ...meta,
                })})`;
            }
            if (this._onExecutableDocumentNode && node.kind === Kind.OPERATION_DEFINITION) {
                const meta = this._getGraphQLCodegenMetadata(node, gqlTag([doc]).definitions);
                if (meta) {
                    if (this._omitDefinitions === true) {
                        return `{${`"__meta__":${JSON.stringify(meta)},`.slice(0, -1)}}`;
                    }
                    return `new TypedDocumentString(\`${doc}\`, ${JSON.stringify(meta)})`;
                }
            }
            return `new TypedDocumentString(\`${doc}\`)`;
        }
        const gqlImport = this._parseImport(this.config.gqlImport || 'graphql-tag');
        return (gqlImport.propName || 'gql') + '`' + doc + '`';
    }
    _getGraphQLCodegenMetadata(node, definitions) {
        let meta;
        if (node.kind === Kind.OPERATION_DEFINITION) {
            meta = this._onExecutableDocumentNode({
                kind: Kind.DOCUMENT,
                definitions,
            });
        }
        const deferredFields = this._findDeferredFields(node);
        if (Object.keys(deferredFields).length) {
            meta = {
                ...meta,
                deferredFields,
            };
        }
        return meta;
    }
    _findDeferredFields(node) {
        const deferredFields = {};
        const queue = [...node.selectionSet.selections];
        while (queue.length) {
            const selection = queue.shift();
            if (selection.kind === Kind.FRAGMENT_SPREAD &&
                selection.directives.some((d) => d.name.value === 'defer')) {
                const fragmentName = selection.name.value;
                const fragment = this.fragmentsGraph.getNodeData(fragmentName);
                if (fragment) {
                    const fields = fragment.node.selectionSet.selections.reduce((acc, selection) => {
                        if (selection.kind === Kind.FIELD) {
                            acc.push(selection.name.value);
                        }
                        return acc;
                    }, []);
                    deferredFields[fragmentName] = fields;
                }
            }
            else if (selection.kind === Kind.FIELD && selection.selectionSet) {
                queue.push(...selection.selectionSet.selections);
            }
        }
        return deferredFields;
    }
    _generateFragment(fragmentDocument) {
        const name = this.getFragmentVariableName(fragmentDocument);
        const fragmentTypeSuffix = this.getFragmentSuffix(fragmentDocument);
        return `export const ${name} =${this.config.pureMagicComment ? ' /*#__PURE__*/' : ''} ${this._gql(fragmentDocument)}${this.getDocumentNodeSignature(this.convertName(fragmentDocument.name.value, {
            useTypesPrefix: true,
            suffix: fragmentTypeSuffix,
        }), this.config.experimentalFragmentVariables
            ? this.convertName(fragmentDocument.name.value, {
                suffix: fragmentTypeSuffix + 'Variables',
            })
            : 'unknown', fragmentDocument)};`;
    }
    _getFragmentsGraph() {
        const graph = new DepGraph({ circular: true });
        for (const fragment of this._fragments.values()) {
            if (graph.hasNode(fragment.name)) {
                const cachedAsString = print(graph.getNodeData(fragment.name).node);
                const asString = print(fragment.node);
                if (cachedAsString !== asString) {
                    throw new Error(`Duplicated fragment called '${fragment.name}'!`);
                }
            }
            graph.addNode(fragment.name, fragment);
        }
        for (const fragment of this._fragments.values()) {
            const depends = this._extractFragments(fragment.node);
            if (depends && depends.length > 0) {
                for (const name of depends) {
                    graph.addDependency(fragment.name, name);
                }
            }
        }
        return graph;
    }
    get fragments() {
        if (this._fragments.size === 0 || this.config.documentMode === DocumentMode.external) {
            return '';
        }
        const graph = this.fragmentsGraph;
        const orderedDeps = graph.overallOrder();
        const localFragments = orderedDeps
            .filter(name => !graph.getNodeData(name).isExternal || this.config.includeExternalFragments)
            .map(name => this._generateFragment(graph.getNodeData(name).node));
        return localFragments.join('\n');
    }
    _parseImport(importStr) {
        // This is a special case when we want to ignore importing, and just use `gql` provided from somewhere else
        // Plugins that uses that will need to ensure to add import/declaration for the gql identifier
        if (importStr === 'gql') {
            return {
                moduleName: null,
                propName: 'gql',
            };
        }
        // This is a special use case, when we don't want this plugin to manage the import statement
        // of the gql tag. In this case, we provide something like `Namespace.gql` and it will be used instead.
        if (importStr.includes('.gql')) {
            return {
                moduleName: null,
                propName: importStr,
            };
        }
        const [moduleName, propName] = importStr.split('#');
        return {
            moduleName,
            propName,
        };
    }
    _generateImport({ moduleName, propName }, varName, isTypeImport) {
        const typeImport = isTypeImport && this.config.useTypeImports ? 'import type' : 'import';
        const propAlias = propName === varName ? '' : ` as ${varName}`;
        if (moduleName) {
            return `${typeImport} ${propName ? `{ ${propName}${propAlias} }` : varName} from '${moduleName}';`;
        }
        return null;
    }
    clearExtension(path) {
        const extension = extname(path);
        const importExtension = normalizeImportExtension({
            emitLegacyCommonJSImports: this.config.emitLegacyCommonJSImports,
            importExtension: this.config.importExtension,
        });
        if (extension === importExtension) {
            return path;
        }
        if (EXTENSIONS_TO_REMOVE.includes(extension)) {
            return path.replace(/\.[^/.]+$/, '');
        }
        return path;
    }
    getImports(options = {}) {
        for (const i of this._additionalImports || []) {
            this._imports.add(i);
        }
        switch (this.config.documentMode) {
            case DocumentMode.documentNode:
            case DocumentMode.documentNodeImportFragments: {
                const documentNodeImport = this._parseImport(this.config.documentNodeImport || 'graphql#DocumentNode');
                const tagImport = this._generateImport(documentNodeImport, 'DocumentNode', true);
                if (tagImport) {
                    this._imports.add(tagImport);
                }
                break;
            }
            case DocumentMode.graphQLTag: {
                const gqlImport = this._parseImport(this.config.gqlImport || 'graphql-tag');
                const tagImport = this._generateImport(gqlImport, 'gql', false);
                if (tagImport) {
                    this._imports.add(tagImport);
                }
                break;
            }
            case DocumentMode.external: {
                if (this._collectedOperations.length > 0) {
                    if (this.config.importDocumentNodeExternallyFrom === 'near-operation-file' &&
                        this._documents.length === 1) {
                        let documentPath = `./${this.clearExtension(basename(this._documents[0].location))}`;
                        documentPath += normalizeImportExtension({
                            emitLegacyCommonJSImports: this.config.emitLegacyCommonJSImports,
                            importExtension: this.config.importExtension,
                        });
                        this._imports.add(`import * as Operations from '${documentPath}';`);
                    }
                    else {
                        if (!this.config.importDocumentNodeExternallyFrom) {
                            // eslint-disable-next-line no-console
                            console.warn('importDocumentNodeExternallyFrom must be provided if documentMode=external');
                        }
                        this._imports.add(`import * as Operations from '${this.clearExtension(this.config.importDocumentNodeExternallyFrom)}';`);
                    }
                }
                break;
            }
            default:
                break;
        }
        const excludeFragments = options.excludeFragments ||
            this.config.globalNamespace ||
            this.config.documentMode !== DocumentMode.graphQLTag;
        if (!excludeFragments) {
            const importExtension = normalizeImportExtension({
                emitLegacyCommonJSImports: this.config.emitLegacyCommonJSImports,
                importExtension: this.config.importExtension,
            });
            const deduplicatedImports = Object.values(groupBy(this.config.fragmentImports, fi => fi.importSource.path))
                .map((fragmentImports) => ({
                ...fragmentImports[0],
                importSource: {
                    ...fragmentImports[0].importSource,
                    identifiers: unique(flatten(fragmentImports.map(fi => fi.importSource.identifiers)), identifier => identifier.name),
                },
                emitLegacyCommonJSImports: this.config.emitLegacyCommonJSImports,
                importExtension,
            }))
                .filter(fragmentImport => fragmentImport.outputPath !== fragmentImport.importSource.path);
            for (const fragmentImport of deduplicatedImports) {
                this._imports.add(generateFragmentImportStatement(fragmentImport, 'document'));
            }
        }
        return Array.from(this._imports);
    }
    buildOperation(_node, _documentVariableName, _operationType, _operationResultType, _operationVariablesTypes, _hasRequiredVariables) {
        return null;
    }
    getDocumentNodeSignature(_resultType, _variablesTypes, _node) {
        if (this.config.documentMode === DocumentMode.documentNode ||
            this.config.documentMode === DocumentMode.documentNodeImportFragments) {
            return ` as unknown as DocumentNode`;
        }
        return '';
    }
    /**
     * Checks if the specific operation has variables that are non-null (required), and also doesn't have default.
     * This is useful for deciding of `variables` should be optional or not.
     * @param node
     */
    checkVariablesRequirements(node) {
        const variables = node.variableDefinitions || [];
        if (variables.length === 0) {
            return false;
        }
        return variables.some(variableDef => variableDef.type.kind === Kind.NON_NULL_TYPE && !variableDef.defaultValue);
    }
    getOperationVariableName(node) {
        return this.convertName(node, {
            suffix: this.config.documentVariableSuffix,
            prefix: this.config.documentVariablePrefix,
            useTypesPrefix: false,
        });
    }
    OperationDefinition(node) {
        this._collectedOperations.push(node);
        const documentVariableName = this.getOperationVariableName(node);
        const operationType = pascalCase(node.operation);
        const operationTypeSuffix = this.getOperationSuffix(node, operationType);
        const operationResultType = this.convertName(node, {
            suffix: operationTypeSuffix + this._parsedConfig.operationResultSuffix,
        });
        const operationVariablesTypes = this.convertName(node, {
            suffix: operationTypeSuffix + 'Variables',
        });
        let documentString = '';
        if (this.config.documentMode !== DocumentMode.external &&
            documentVariableName !== '' // only generate exports for named queries
        ) {
            documentString = `${this.config.noExport ? '' : 'export'} const ${documentVariableName} =${this.config.pureMagicComment ? ' /*#__PURE__*/' : ''} ${this._gql(node)}${this.getDocumentNodeSignature(operationResultType, operationVariablesTypes, node)};`;
        }
        const hasRequiredVariables = this.checkVariablesRequirements(node);
        const additional = this.buildOperation(node, documentVariableName, operationType, operationResultType, operationVariablesTypes, hasRequiredVariables);
        return [documentString, additional].filter(a => a).join('\n');
    }
}
