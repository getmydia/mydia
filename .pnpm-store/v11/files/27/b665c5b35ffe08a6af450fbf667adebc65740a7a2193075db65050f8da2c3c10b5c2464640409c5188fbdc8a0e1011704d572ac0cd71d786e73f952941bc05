import { TypeNode } from 'graphql';
import { ConvertNameFn, NormalizedScalarsMap, OperationVariablesToObject, ParsedEnumValuesMap, type NormalizedOperationAvoidOptionalsConfig } from '@graphql-codegen/visitor-plugin-common';
export declare class TypeScriptOperationVariablesToObject extends OperationVariablesToObject {
    private _config;
    constructor(_config: {
        avoidOptionals: NormalizedOperationAvoidOptionalsConfig;
        immutableTypes: boolean;
        inputMaybeValue: string;
    }, _scalars: NormalizedScalarsMap, _convertName: ConvertNameFn, _namespacedImportName: string | null, _enumNames: string[], _enumPrefix: boolean, _enumSuffix: boolean, _enumValues: ParsedEnumValuesMap, _applyCoercion: boolean);
    protected formatFieldString(fieldName: string, isNonNullType: boolean, hasDefaultValue: boolean): string;
    protected formatTypeString(fieldType: string, _isNonNullType: boolean, _hasDefaultValue: boolean): string;
    protected clearOptional(str: string): string;
    protected getAvoidOption(isNonNullType: boolean, hasDefaultValue: boolean): boolean;
    protected getScalar(name: string): string;
    protected getPunctuation(): string;
    wrapAstTypeWithModifiers(baseType: string, typeNode: TypeNode, applyCoercion?: boolean): string;
    protected wrapMaybe(type: string): string;
}
