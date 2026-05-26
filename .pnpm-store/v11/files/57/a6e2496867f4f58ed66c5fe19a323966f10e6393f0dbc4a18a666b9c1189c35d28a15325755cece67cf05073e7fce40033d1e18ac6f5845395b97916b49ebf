import autoBind from 'auto-bind';
import { pascalCase } from 'change-case-all';
import { BaseVisitor } from './base-visitor.js';
import { normalizeOperationAvoidOptionals, } from './operation-avoid-optionals.js';
import { normalizeOperationDeclarationKind, } from './operation-declaration-kinds.js';
import { DEFAULT_INPUT_SCALARS } from './scalars.js';
import { buildScalarsFromConfig, DeclarationBlock, getConfigValue, } from './utils.js';
import { OperationVariablesToObject } from './variables-to-object.js';
export class BaseDocumentsVisitor extends BaseVisitor {
    _schema;
    _unnamedCounter = 1;
    _variablesTransfomer;
    _selectionSetToObject;
    _globalDeclarations = new Set();
    constructor(rawConfig, additionalConfig, _schema, defaultScalars = DEFAULT_INPUT_SCALARS) {
        const importSchemaTypesFrom = getConfigValue(rawConfig.importSchemaTypesFrom, '');
        const extractAllFieldsToTypes = getConfigValue(rawConfig.extractAllFieldsToTypes, false) ||
            getConfigValue(rawConfig.extractAllFieldsToTypesCompact, false);
        const declarationKind = normalizeOperationDeclarationKind(getConfigValue(rawConfig.declarationKind, 'type'));
        if (extractAllFieldsToTypes && declarationKind.result === 'interface') {
            // eslint-disable-next-line no-console
            console.warn("`declarationKind.result` has been set to `'type'` because `extractAllFieldsToTypes` or `extractAllFieldsToTypesCompact` is true");
            declarationKind.result = 'type';
        }
        super(rawConfig, {
            avoidOptionals: normalizeOperationAvoidOptionals(getConfigValue(rawConfig.avoidOptionals, false)),
            exportFragmentSpreadSubTypes: getConfigValue(rawConfig.exportFragmentSpreadSubTypes, false),
            dedupeOperationSuffix: getConfigValue(rawConfig.dedupeOperationSuffix, false),
            omitOperationSuffix: getConfigValue(rawConfig.omitOperationSuffix, false),
            skipTypeNameForRoot: getConfigValue(rawConfig.skipTypeNameForRoot, false),
            nonOptionalTypename: getConfigValue(rawConfig.nonOptionalTypename, false),
            experimentalFragmentVariables: getConfigValue(rawConfig.experimentalFragmentVariables, false),
            globalNamespace: !!rawConfig.globalNamespace,
            operationResultSuffix: getConfigValue(rawConfig.operationResultSuffix, ''),
            scalars: buildScalarsFromConfig(_schema, rawConfig, defaultScalars),
            customDirectives: getConfigValue(rawConfig.customDirectives, { apolloUnmask: false }),
            generateOperationTypes: getConfigValue(rawConfig.generateOperationTypes, true),
            importSchemaTypesFrom,
            namespacedImportName: getConfigValue(rawConfig.namespacedImportName, importSchemaTypesFrom ? 'Types' : null),
            extractAllFieldsToTypes,
            extractAllFieldsToTypesCompact: getConfigValue(rawConfig.extractAllFieldsToTypesCompact, false),
            declarationKind,
            ...(additionalConfig || {}),
        });
        this._schema = _schema;
        autoBind(this);
        this._variablesTransfomer = new OperationVariablesToObject(this.scalars, this.convertName, this.config.namespacedImportName);
    }
    getGlobalDeclarations(noExport = false) {
        return Array.from(this._globalDeclarations).map(t => (noExport ? t : `export ${t}`));
    }
    setSelectionSetHandler(handler) {
        this._selectionSetToObject = handler;
    }
    setDeclarationBlockConfig(config) {
        this._declarationBlockConfig = config;
    }
    setVariablesTransformer(variablesTransfomer) {
        this._variablesTransfomer = variablesTransfomer;
    }
    get schema() {
        return this._schema;
    }
    handleAnonymousOperation(node) {
        const name = node.name?.value;
        if (name) {
            return this.convertName(name, {
                useTypesPrefix: false,
                useTypesSuffix: false,
            });
        }
        return this.convertName(String(this._unnamedCounter++), {
            prefix: 'Unnamed_',
            suffix: '_',
            useTypesPrefix: false,
            useTypesSuffix: false,
        });
    }
    FragmentDefinition(node) {
        if (!this.config.generateOperationTypes) {
            return null;
        }
        const fragmentRootType = this._schema.getType(node.typeCondition.name.value);
        const selectionSet = this._selectionSetToObject.createNext(fragmentRootType, node.selectionSet);
        const fragmentSuffix = this.getFragmentSuffix(node);
        return [
            selectionSet.transformFragmentSelectionSetToTypes(node.name.value, fragmentSuffix, this._declarationBlockConfig),
            this.config.experimentalFragmentVariables
                ? new DeclarationBlock({
                    ...this._declarationBlockConfig,
                    blockTransformer: t => this.applyVariablesWrapper(t),
                })
                    .export()
                    .asKind('type')
                    .withName(this.convertName(node.name.value, {
                    suffix: fragmentSuffix + 'Variables',
                }))
                    .withBlock(this._variablesTransfomer.transform(node.variableDefinitions)).string
                : undefined,
        ]
            .filter(r => r)
            .join('\n\n');
    }
    applyVariablesWrapper(variablesBlock, _operationType) {
        return variablesBlock;
    }
    OperationDefinition(node) {
        if (!this.config.generateOperationTypes) {
            return null;
        }
        const name = this.handleAnonymousOperation(node);
        const operationRootType = getRootType(node.operation, this._schema);
        if (!operationRootType) {
            throw new Error(`Unable to find root schema type for operation type "${node.operation}"!`);
        }
        const selectionSet = this._selectionSetToObject.createNext(operationRootType, node.selectionSet);
        const visitedOperationVariables = this._variablesTransfomer.transform(node.variableDefinitions);
        const operationType = pascalCase(node.operation);
        const operationTypeSuffix = this.getOperationSuffix(name, operationType);
        const selectionSetObjects = selectionSet.transformSelectionSet(this.convertName(name, {
            suffix: operationTypeSuffix,
        }));
        const operationResultName = this.convertName(name, {
            suffix: operationTypeSuffix + this._parsedConfig.operationResultSuffix,
        });
        // When extractAllFieldsToTypes creates a root type with the same name as the operation result,
        // we only need the extracted type and can skip the alias to avoid duplicates
        const shouldSkipOperationResult = this._parsedConfig.extractAllFieldsToTypesCompact &&
            operationResultName === selectionSetObjects.mergedTypeString;
        const operationResult = shouldSkipOperationResult
            ? ''
            : new DeclarationBlock(this._declarationBlockConfig)
                .export()
                .asKind(this.config.declarationKind.result)
                .withName(operationResultName)
                .withContent(selectionSetObjects.mergedTypeString).string;
        const operationVariables = new DeclarationBlock({
            ...this._declarationBlockConfig,
            blockTransformer: t => this.applyVariablesWrapper(t, operationType),
        })
            .export()
            .asKind('type') // Variables must always be `'type'` because it is an alias of `Exact<Something>`
            .withName(this.convertName(name, {
            suffix: operationTypeSuffix + 'Variables',
        }))
            .withBlock(visitedOperationVariables).string;
        const dependentTypesContent = this._parsedConfig.extractAllFieldsToTypes
            ? selectionSetObjects.dependentTypes.map(i => new DeclarationBlock(this._declarationBlockConfig)
                .export()
                .asKind('type') // dependentTypes must always be `'type'` because they are alias types
                .withName(i.name)
                .withContent(i.content).string)
            : [];
        return [
            ...(dependentTypesContent.length > 0 ? [dependentTypesContent.join('\n')] : []),
            operationVariables,
            operationResult,
        ]
            .filter(r => r)
            .join('\n\n');
    }
}
function getRootType(operation, schema) {
    switch (operation) {
        case 'query':
            return schema.getQueryType();
        case 'mutation':
            return schema.getMutationType();
        case 'subscription':
            return schema.getSubscriptionType();
    }
    throw new Error(`Unknown operation type: ${operation}`);
}
