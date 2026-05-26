import { Kind } from 'graphql';
import { DEFAULT_INPUT_SCALARS, OperationVariablesToObject, printTypeScriptMaybeType, } from '@graphql-codegen/visitor-plugin-common';
export class TypeScriptOperationVariablesToObject extends OperationVariablesToObject {
    _config;
    constructor(_config, _scalars, _convertName, _namespacedImportName, _enumNames, _enumPrefix, _enumSuffix, _enumValues, _applyCoercion) {
        super(_scalars, _convertName, _namespacedImportName, _enumNames, _enumPrefix, _enumSuffix, _enumValues, _applyCoercion, {});
        this._config = _config;
    }
    formatFieldString(fieldName, isNonNullType, hasDefaultValue) {
        return `${fieldName}${this.getAvoidOption(isNonNullType, hasDefaultValue) ? '?' : ''}`;
    }
    formatTypeString(fieldType, _isNonNullType, _hasDefaultValue) {
        return fieldType;
    }
    clearOptional(str) {
        const maybeSuffix = this._config.inputMaybeValue.replace('T', ''); // e.g. turns `T | null | undefined` to ` | null | undefined`
        if (str.endsWith(maybeSuffix)) {
            return (str = str.substring(0, str.length - maybeSuffix.length));
        }
        return str;
    }
    getAvoidOption(isNonNullType, hasDefaultValue) {
        const options = this._config.avoidOptionals;
        return (((options.variableValue || !options.defaultValue) && hasDefaultValue) ||
            (!options.variableValue && !isNonNullType));
    }
    getScalar(name) {
        return this._scalars[name]?.input ?? DEFAULT_INPUT_SCALARS[name].input ?? 'unknown';
    }
    getPunctuation() {
        return ';';
    }
    wrapAstTypeWithModifiers(baseType, typeNode, applyCoercion = false) {
        if (typeNode.kind === Kind.NON_NULL_TYPE) {
            const type = this.wrapAstTypeWithModifiers(baseType, typeNode.type, applyCoercion);
            return this.clearOptional(type);
        }
        if (typeNode.kind === Kind.LIST_TYPE) {
            const innerType = this.wrapAstTypeWithModifiers(baseType, typeNode.type, applyCoercion);
            const listInputCoercionExtension = applyCoercion ? ` | ${innerType}` : '';
            return this.wrapMaybe(`${this._config.immutableTypes ? 'ReadonlyArray' : 'Array'}<${innerType}>${listInputCoercionExtension}`);
        }
        return this.wrapMaybe(baseType);
    }
    wrapMaybe(type) {
        return printTypeScriptMaybeType({
            type,
            pattern: this._config.inputMaybeValue,
        });
    }
}
