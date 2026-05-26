import type { EnumTypeDefinitionNode, EnumValueDefinitionNode, GraphQLSchema } from 'graphql';
import type { ConvertFn, ParsedEnumValuesMap } from './types.cjs';
import { type DeclarationBlockConfig } from './utils.cjs';
export interface ConvertSchemaEnumToDeclarationBlockString {
    schema: GraphQLSchema;
    node: EnumTypeDefinitionNode;
    enumName: string;
    enumValues: ParsedEnumValuesMap;
    futureProofEnums: boolean;
    ignoreEnumValuesFromSchema: boolean;
    naming: {
        convert: ConvertFn;
        options: {
            typesPrefix: string;
            typesSuffix: string;
            useTypesPrefix?: boolean;
            useTypesSuffix?: boolean;
        };
    };
    outputType: 'string-literal' | 'native-numeric' | 'const' | 'native-const' | 'native';
    declarationBlockConfig: DeclarationBlockConfig;
}
export declare const convertSchemaEnumToDeclarationBlockString: ({ schema, node, enumName, enumValues, futureProofEnums, ignoreEnumValuesFromSchema, outputType, declarationBlockConfig, naming, }: ConvertSchemaEnumToDeclarationBlockString) => string;
export declare const buildEnumValuesBlock: ({ typeName, values, schema, naming, ignoreEnumValuesFromSchema, declarationBlockConfig, enumValues, }: Pick<ConvertSchemaEnumToDeclarationBlockString, "schema" | "naming" | "ignoreEnumValuesFromSchema" | "declarationBlockConfig" | "enumValues"> & {
    typeName: string;
    values: ReadonlyArray<EnumValueDefinitionNode>;
}) => string;
