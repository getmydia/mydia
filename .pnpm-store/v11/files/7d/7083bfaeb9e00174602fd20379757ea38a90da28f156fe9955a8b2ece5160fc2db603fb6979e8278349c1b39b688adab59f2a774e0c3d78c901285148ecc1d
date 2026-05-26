"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.BaseDocumentsVisitor = void 0;
const tslib_1 = require("tslib");
const auto_bind_1 = tslib_1.__importDefault(require("auto-bind"));
const change_case_all_1 = require("change-case-all");
const base_visitor_js_1 = require("./base-visitor.js");
const operation_avoid_optionals_js_1 = require("./operation-avoid-optionals.js");
const operation_declaration_kinds_js_1 = require("./operation-declaration-kinds.js");
const scalars_js_1 = require("./scalars.js");
const utils_js_1 = require("./utils.js");
const variables_to_object_js_1 = require("./variables-to-object.js");
class BaseDocumentsVisitor extends base_visitor_js_1.BaseVisitor {
    _schema;
    _unnamedCounter = 1;
    _variablesTransfomer;
    _selectionSetToObject;
    _globalDeclarations = new Set();
    constructor(rawConfig, additionalConfig, _schema, defaultScalars = scalars_js_1.DEFAULT_INPUT_SCALARS) {
        const importSchemaTypesFrom = (0, utils_js_1.getConfigValue)(rawConfig.importSchemaTypesFrom, '');
        const extractAllFieldsToTypes = (0, utils_js_1.getConfigValue)(rawConfig.extractAllFieldsToTypes, false) ||
            (0, utils_js_1.getConfigValue)(rawConfig.extractAllFieldsToTypesCompact, false);
        const declarationKind = (0, operation_declaration_kinds_js_1.normalizeOperationDeclarationKind)((0, utils_js_1.getConfigValue)(rawConfig.declarationKind, 'type'));
        if (extractAllFieldsToTypes && declarationKind.result === 'interface') {
            // eslint-disable-next-line no-console
            console.warn("`declarationKind.result` has been set to `'type'` because `extractAllFieldsToTypes` or `extractAllFieldsToTypesCompact` is true");
            declarationKind.result = 'type';
        }
        super(rawConfig, {
            avoidOptionals: (0, operation_avoid_optionals_js_1.normalizeOperationAvoidOptionals)((0, utils_js_1.getConfigValue)(rawConfig.avoidOptionals, false)),
            exportFragmentSpreadSubTypes: (0, utils_js_1.getConfigValue)(rawConfig.exportFragmentSpreadSubTypes, false),
            dedupeOperationSuffix: (0, utils_js_1.getConfigValue)(rawConfig.dedupeOperationSuffix, false),
            omitOperationSuffix: (0, utils_js_1.getConfigValue)(rawConfig.omitOperationSuffix, false),
            skipTypeNameForRoot: (0, utils_js_1.getConfigValue)(rawConfig.skipTypeNameForRoot, false),
            nonOptionalTypename: (0, utils_js_1.getConfigValue)(rawConfig.nonOptionalTypename, false),
            experimentalFragmentVariables: (0, utils_js_1.getConfigValue)(rawConfig.experimentalFragmentVariables, false),
            globalNamespace: !!rawConfig.globalNamespace,
            operationResultSuffix: (0, utils_js_1.getConfigValue)(rawConfig.operationResultSuffix, ''),
            scalars: (0, utils_js_1.buildScalarsFromConfig)(_schema, rawConfig, defaultScalars),
            customDirectives: (0, utils_js_1.getConfigValue)(rawConfig.customDirectives, { apolloUnmask: false }),
            generateOperationTypes: (0, utils_js_1.getConfigValue)(rawConfig.generateOperationTypes, true),
            importSchemaTypesFrom,
            namespacedImportName: (0, utils_js_1.getConfigValue)(rawConfig.namespacedImportName, importSchemaTypesFrom ? 'Types' : null),
            extractAllFieldsToTypes,
            extractAllFieldsToTypesCompact: (0, utils_js_1.getConfigValue)(rawConfig.extractAllFieldsToTypesCompact, false),
            declarationKind,
            ...(additionalConfig || {}),
        });
        this._schema = _schema;
        (0, auto_bind_1.default)(this);
        this._variablesTransfomer = new variables_to_object_js_1.OperationVariablesToObject(this.scalars, this.convertName, this.config.namespacedImportName);
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
                ? new utils_js_1.DeclarationBlock({
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
        const operationType = (0, change_case_all_1.pascalCase)(node.operation);
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
            : new utils_js_1.DeclarationBlock(this._declarationBlockConfig)
                .export()
                .asKind(this.config.declarationKind.result)
                .withName(operationResultName)
                .withContent(selectionSetObjects.mergedTypeString).string;
        const operationVariables = new utils_js_1.DeclarationBlock({
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
            ? selectionSetObjects.dependentTypes.map(i => new utils_js_1.DeclarationBlock(this._declarationBlockConfig)
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
exports.BaseDocumentsVisitor = BaseDocumentsVisitor;
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
