"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.UrqlVisitor = void 0;
const tslib_1 = require("tslib");
const auto_bind_1 = tslib_1.__importDefault(require("auto-bind"));
const graphql_1 = require("graphql");
const visitor_plugin_common_1 = require("@graphql-codegen/visitor-plugin-common");
class UrqlVisitor extends visitor_plugin_common_1.ClientSideBaseVisitor {
    constructor(schema, fragments, rawConfig) {
        super(schema, fragments, rawConfig, {
            withComponent: (0, visitor_plugin_common_1.getConfigValue)(rawConfig.withComponent, false),
            withHooks: (0, visitor_plugin_common_1.getConfigValue)(rawConfig.withHooks, true),
            urqlImportFrom: (0, visitor_plugin_common_1.getConfigValue)(rawConfig.urqlImportFrom, null),
        });
        this._externalImportPrefix = '';
        if (this.config.importOperationTypesFrom) {
            this._externalImportPrefix = `${this.config.importOperationTypesFrom}.`;
            if (this.config.documentMode !== visitor_plugin_common_1.DocumentMode.external ||
                !this.config.importDocumentNodeExternallyFrom) {
                // eslint-disable-next-line no-console
                console.warn('"importOperationTypesFrom" should be used with "documentMode=external" and "importDocumentNodeExternallyFrom"');
            }
            if (this.config.importOperationTypesFrom !== 'Operations') {
                // eslint-disable-next-line no-console
                console.warn('importOperationTypesFrom only works correctly when left empty or set to "Operations"');
            }
        }
        (0, auto_bind_1.default)(this);
    }
    getImports() {
        const baseImports = super.getImports();
        const imports = [];
        const hasOperations = this._collectedOperations.length > 0;
        if (!hasOperations) {
            return baseImports;
        }
        if (this.config.withComponent) {
            imports.push(`import * as React from 'react';`);
        }
        if (this.config.withComponent || this.config.withHooks) {
            imports.push(`import * as Urql from '${this.config.urqlImportFrom || 'urql'}';`);
        }
        imports.push(visitor_plugin_common_1.OMIT_TYPE);
        return [...baseImports, ...imports];
    }
    _buildComponent(node, documentVariableName, operationType, operationResultType, operationVariablesTypes) {
        var _a, _b;
        const componentName = this.convertName((_b = (_a = node.name) === null || _a === void 0 ? void 0 : _a.value) !== null && _b !== void 0 ? _b : '', {
            suffix: 'Component',
            useTypesPrefix: false,
        });
        const isVariablesRequired = operationType === 'Query' &&
            node.variableDefinitions.some(variableDef => variableDef.type.kind === graphql_1.Kind.NON_NULL_TYPE);
        const generics = [operationResultType, operationVariablesTypes];
        if (operationType === 'Subscription') {
            generics.unshift(operationResultType);
        }
        return `
export const ${componentName} = (props: Omit<Urql.${operationType}Props<${generics.join(', ')}>, 'query'> & { variables${isVariablesRequired ? '' : '?'}: ${operationVariablesTypes} }) => (
  <Urql.${operationType} {...props} query={${documentVariableName}} />
);
`;
    }
    _buildHooks(node, operationType, documentVariableName, operationResultType, operationVariablesTypes) {
        var _a, _b;
        const operationName = this.convertName((_b = (_a = node.name) === null || _a === void 0 ? void 0 : _a.value) !== null && _b !== void 0 ? _b : '', {
            suffix: this.getOperationSuffix(node, operationType),
            useTypesPrefix: false,
        });
        if (operationType === 'Mutation') {
            return `
export function use${operationName}() {
  return Urql.use${operationType}<${operationResultType}, ${operationVariablesTypes}>(${documentVariableName});
};`;
        }
        const isVariablesRequired = node.variableDefinitions.some(variableDef => variableDef.type.kind === graphql_1.Kind.NON_NULL_TYPE && variableDef.defaultValue == null);
        if (operationType === 'Subscription') {
            return `
export function use${operationName}<TData = ${operationResultType}>(options${isVariablesRequired ? '' : '?'}: Omit<Urql.Use${operationType}Args<${operationVariablesTypes}>, 'query'>, handler?: Urql.SubscriptionHandler<${operationResultType}, TData>) {
  return Urql.use${operationType}<${operationResultType}, TData, ${operationVariablesTypes}>({ query: ${documentVariableName}, ...options }, handler);
};`;
        }
        return `
export function use${operationName}(options${isVariablesRequired ? '' : '?'}: Omit<Urql.Use${operationType}Args<${operationVariablesTypes}>, 'query'>) {
  return Urql.use${operationType}<${operationResultType}, ${operationVariablesTypes}>({ query: ${documentVariableName}, ...options });
};`;
    }
    buildOperation(node, documentVariableName, operationType, operationResultType, operationVariablesTypes) {
        const documentVariablePrefixed = this._externalImportPrefix + documentVariableName;
        const operationResultTypePrefixed = this._externalImportPrefix + operationResultType;
        const operationVariablesTypesPrefixed = this._externalImportPrefix + operationVariablesTypes;
        const component = this.config.withComponent
            ? this._buildComponent(node, documentVariablePrefixed, operationType, operationResultTypePrefixed, operationVariablesTypesPrefixed)
            : null;
        const hooks = this.config.withHooks
            ? this._buildHooks(node, operationType, documentVariablePrefixed, operationResultTypePrefixed, operationVariablesTypesPrefixed)
            : null;
        return [component, hooks].filter(a => a).join('\n');
    }
}
exports.UrqlVisitor = UrqlVisitor;
