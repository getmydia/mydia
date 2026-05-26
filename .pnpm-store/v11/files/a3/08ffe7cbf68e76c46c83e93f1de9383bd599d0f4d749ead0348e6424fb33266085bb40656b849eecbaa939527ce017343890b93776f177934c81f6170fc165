import { GraphQLSchema } from 'graphql';
import type { ConvertFn, EnumValuesMap, ParsedEnumValuesMap } from './types.js';
export declare function parseEnumValues({ schema, mapOrStr, ignoreEnumValuesFromSchema, naming, }: {
    schema: GraphQLSchema;
    mapOrStr: EnumValuesMap;
    ignoreEnumValuesFromSchema?: boolean;
    naming: {
        convert: ConvertFn;
        options: {
            typesPrefix: string;
            typesSuffix: string;
            useTypesPrefix?: boolean;
            useTypesSuffix?: boolean;
        };
    };
}): ParsedEnumValuesMap;
