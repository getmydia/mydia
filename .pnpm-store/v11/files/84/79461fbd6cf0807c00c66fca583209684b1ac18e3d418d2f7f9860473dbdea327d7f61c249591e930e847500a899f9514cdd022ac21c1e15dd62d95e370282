"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.buildEnumValuesBlock = exports.convertSchemaEnumToDeclarationBlockString = void 0;
const naming_js_1 = require("./naming.js");
const utils_js_1 = require("./utils.js");
const convertSchemaEnumToDeclarationBlockString = ({ schema, node, enumName, enumValues, futureProofEnums, ignoreEnumValuesFromSchema, outputType, declarationBlockConfig, naming, }) => {
    if (enumValues[enumName]?.sourceFile) {
        return `export { ${enumValues[enumName].typeIdentifierConverted} };\n`;
    }
    const getValueFromConfig = (enumValue) => {
        if (typeof enumValues[enumName]?.mappedValues?.[enumValue] !== 'undefined') {
            return enumValues[enumName].mappedValues[enumValue];
        }
        return null;
    };
    const withFutureAddedValue = [
        futureProofEnums ? [(0, utils_js_1.indent)('| ' + (0, utils_js_1.wrapWithSingleQuotes)('%future added value'))] : [],
    ];
    const enumTypeName = (0, naming_js_1.convertName)({
        convert: () => naming.convert(node),
        options: naming.options,
    });
    if (outputType === 'string-literal') {
        return new utils_js_1.DeclarationBlock(declarationBlockConfig)
            .export()
            .asKind('type')
            .withComment(node.description?.value)
            .withName(enumTypeName)
            .withContent('\n' +
            node.values
                .map(enumOption => {
                const name = enumOption.name.value;
                const enumValue = getValueFromConfig(name) ?? name;
                const comment = (0, utils_js_1.transformComment)(enumOption.description?.value, 1);
                return comment + (0, utils_js_1.indent)('| ' + (0, utils_js_1.wrapWithSingleQuotes)(enumValue));
            })
                .concat(...withFutureAddedValue)
                .join('\n')).string;
    }
    if (outputType === 'native-numeric') {
        return new utils_js_1.DeclarationBlock(declarationBlockConfig)
            .export()
            .withComment(node.description?.value)
            .withName(enumTypeName)
            .asKind('enum')
            .withBlock(node.values
            .map((enumOption, i) => {
            const valueFromConfig = getValueFromConfig(enumOption.name.value);
            const enumValue = valueFromConfig ?? i;
            const comment = (0, utils_js_1.transformComment)(enumOption.description?.value, 1);
            const optionName = makeValidEnumIdentifier((0, naming_js_1.convertName)({
                options: {
                    typesPrefix: naming.options.typesPrefix,
                    typesSuffix: naming.options.typesSuffix,
                    useTypesPrefix: false,
                },
                convert: () => naming.convert(enumOption, { transformUnderscore: true }),
            }));
            return comment + (0, utils_js_1.indent)(optionName) + ` = ${enumValue}`;
        })
            .concat(...withFutureAddedValue)
            .join(',\n')).string;
    }
    if (outputType === 'const') {
        const typeName = `export type ${enumTypeName} = typeof ${enumTypeName}[keyof typeof ${enumTypeName}];`;
        const enumAsConst = new utils_js_1.DeclarationBlock({
            ...declarationBlockConfig,
            blockTransformer: block => {
                return block + ' as const';
            },
        })
            .export()
            .asKind('const')
            .withName(enumTypeName)
            .withComment(node.description?.value)
            .withBlock(node.values
            .map(enumOption => {
            const optionName = makeValidEnumIdentifier((0, naming_js_1.convertName)({
                options: {
                    typesPrefix: naming.options.typesPrefix,
                    typesSuffix: naming.options.typesSuffix,
                },
                convert: () => naming.convert(enumOption, {
                    transformUnderscore: true,
                }),
            }));
            const comment = (0, utils_js_1.transformComment)(enumOption.description?.value, 1);
            const name = enumOption.name.value;
            const enumValue = getValueFromConfig(name) ?? name;
            return comment + (0, utils_js_1.indent)(`${optionName}: ${(0, utils_js_1.wrapWithSingleQuotes)(enumValue)}`);
        })
            .join(',\n')).string;
        return [enumAsConst, typeName].join('\n');
    }
    return new utils_js_1.DeclarationBlock(declarationBlockConfig)
        .export()
        .asKind(outputType === 'native-const' ? 'const enum' : 'enum')
        .withName(enumTypeName)
        .withComment(node.description?.value)
        .withBlock((0, exports.buildEnumValuesBlock)({
        typeName: enumName,
        values: node.values,
        schema,
        naming,
        ignoreEnumValuesFromSchema,
        declarationBlockConfig,
        enumValues,
    })).string;
};
exports.convertSchemaEnumToDeclarationBlockString = convertSchemaEnumToDeclarationBlockString;
const buildEnumValuesBlock = ({ typeName, values, schema, naming, ignoreEnumValuesFromSchema, declarationBlockConfig, enumValues, }) => {
    const schemaEnumType = schema
        ? schema.getType(typeName)
        : undefined;
    return values
        .map(enumOption => {
        const onlyUnderscoresPattern = /^_+$/;
        const optionName = makeValidEnumIdentifier((0, naming_js_1.convertName)({
            options: {
                useTypesPrefix: false,
                typesPrefix: naming.options.typesPrefix,
                typesSuffix: naming.options.typesSuffix,
            },
            convert: () => naming.convert(enumOption, {
                // We can only strip out the underscores if the value contains other
                // characters. Otherwise we'll generate syntactically invalid code.
                transformUnderscore: !onlyUnderscoresPattern.test(enumOption.name.value),
            }),
        }));
        const comment = (0, utils_js_1.getNodeComment)(enumOption);
        const schemaEnumValue = schemaEnumType && !ignoreEnumValuesFromSchema
            ? schemaEnumType.getValue(enumOption.name.value).value
            : undefined;
        let enumValue = typeof schemaEnumValue === 'undefined' ? enumOption.name.value : schemaEnumValue;
        if (typeof enumValues[typeName]?.mappedValues?.[enumValue] !== 'undefined') {
            enumValue = enumValues[typeName].mappedValues[enumValue];
        }
        return (comment +
            (0, utils_js_1.indent)(`${optionName}${declarationBlockConfig.enumNameValueSeparator} ${(0, utils_js_1.wrapWithSingleQuotes)(enumValue, typeof schemaEnumValue !== 'undefined')}`));
    })
        .join(',\n');
};
exports.buildEnumValuesBlock = buildEnumValuesBlock;
const makeValidEnumIdentifier = (identifier) => {
    if (/^[0-9]/.exec(identifier)) {
        return (0, utils_js_1.wrapWithSingleQuotes)(identifier, true);
    }
    return identifier;
};
