import { TypeNode } from 'graphql';
import { ConvertNameFn, NormalizedAvoidOptionalsConfig, NormalizedScalarsMap, OperationVariablesToObject, ParsedDirectiveArgumentAndInputFieldMappings, ParsedEnumValuesMap } from '@graphql-codegen/visitor-plugin-common';
export declare class TypeScriptOperationVariablesToObject extends OperationVariablesToObject {
    private _avoidOptionals;
    private _immutableTypes;
    private _maybeType;
    constructor(_scalars: NormalizedScalarsMap, _convertName: ConvertNameFn, _avoidOptionals: NormalizedAvoidOptionalsConfig, _immutableTypes: boolean, _namespacedImportName?: string | null, _enumNames?: string[], _enumPrefix?: boolean, _enumSuffix?: boolean, _enumValues?: ParsedEnumValuesMap, _applyCoercion?: boolean, _directiveArgumentAndInputFieldMappings?: ParsedDirectiveArgumentAndInputFieldMappings, _maybeType?: string);
    protected clearOptional(str: string): string;
    wrapAstTypeWithModifiers(baseType: string, typeNode: TypeNode, applyCoercion?: boolean): string;
    protected formatFieldString(fieldName: string, isNonNullType: boolean, hasDefaultValue: boolean): string;
    protected formatTypeString(fieldType: string, isNonNullType: boolean, hasDefaultValue: boolean): string;
    protected wrapMaybe(type?: string): string;
    protected getAvoidOption(isNonNullType: boolean, hasDefaultValue: boolean): boolean;
    protected getPunctuation(): string;
}
