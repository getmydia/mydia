"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.TypeScriptOperationVariablesToObject = void 0;
const graphql_1 = require("graphql");
const visitor_plugin_common_1 = require("@graphql-codegen/visitor-plugin-common");
class TypeScriptOperationVariablesToObject extends visitor_plugin_common_1.OperationVariablesToObject {
    _avoidOptionals;
    _immutableTypes;
    _maybeType;
    constructor(_scalars, _convertName, _avoidOptionals, _immutableTypes, _namespacedImportName = null, _enumNames = [], _enumPrefix = true, _enumSuffix = true, _enumValues = {}, _applyCoercion = false, _directiveArgumentAndInputFieldMappings = {}, _maybeType = 'Maybe') {
        super(_scalars, _convertName, _namespacedImportName, _enumNames, _enumPrefix, _enumSuffix, _enumValues, _applyCoercion, _directiveArgumentAndInputFieldMappings);
        this._avoidOptionals = _avoidOptionals;
        this._immutableTypes = _immutableTypes;
        this._maybeType = _maybeType;
    }
    clearOptional(str) {
        const prefix = this._namespacedImportName ? `${this._namespacedImportName}.` : '';
        const rgx = new RegExp(`^${this.wrapMaybe(`(.*?)`)}$`, 'i');
        if (str.startsWith(`${prefix}${this._maybeType}`)) {
            return str.replace(rgx, '$1');
        }
        return str;
    }
    wrapAstTypeWithModifiers(baseType, typeNode, applyCoercion = false) {
        if (typeNode.kind === graphql_1.Kind.NON_NULL_TYPE) {
            const type = this.wrapAstTypeWithModifiers(baseType, typeNode.type, applyCoercion);
            return this.clearOptional(type);
        }
        if (typeNode.kind === graphql_1.Kind.LIST_TYPE) {
            const innerType = this.wrapAstTypeWithModifiers(baseType, typeNode.type, applyCoercion);
            const listInputCoercionExtension = applyCoercion ? ` | ${innerType}` : '';
            return this.wrapMaybe(`${this._immutableTypes ? 'ReadonlyArray' : 'Array'}<${innerType}>${listInputCoercionExtension}`);
        }
        return this.wrapMaybe(baseType);
    }
    formatFieldString(fieldName, isNonNullType, hasDefaultValue) {
        return `${fieldName}${this.getAvoidOption(isNonNullType, hasDefaultValue) ? '?' : ''}`;
    }
    formatTypeString(fieldType, isNonNullType, hasDefaultValue) {
        if (!hasDefaultValue && isNonNullType) {
            return this.clearOptional(fieldType);
        }
        return fieldType;
    }
    wrapMaybe(type) {
        const prefix = this._namespacedImportName ? `${this._namespacedImportName}.` : '';
        return `${prefix}${this._maybeType}${type ? `<${type}>` : ''}`;
    }
    getAvoidOption(isNonNullType, hasDefaultValue) {
        const options = this._avoidOptionals;
        return (((options.object || !options.defaultValue) && hasDefaultValue) ||
            (!options.object && !isNonNullType));
    }
    getPunctuation() {
        return ';';
    }
}
exports.TypeScriptOperationVariablesToObject = TypeScriptOperationVariablesToObject;
