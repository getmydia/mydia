"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.TsVisitor = void 0;
const tslib_1 = require("tslib");
const auto_bind_1 = tslib_1.__importDefault(require("auto-bind"));
const graphql_1 = require("graphql");
const visitor_plugin_common_1 = require("@graphql-codegen/visitor-plugin-common");
const typescript_variables_to_object_js_1 = require("./typescript-variables-to-object.js");
class TsVisitor extends visitor_plugin_common_1.BaseTypesVisitor {
    constructor(schema, pluginConfig, additionalConfig = {}) {
        super(schema, pluginConfig, {
            noExport: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.noExport, false),
            avoidOptionals: (0, visitor_plugin_common_1.normalizeAvoidOptionals)((0, visitor_plugin_common_1.getConfigValue)(pluginConfig.avoidOptionals, false)),
            maybeValue: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.maybeValue, 'T | null'),
            inputMaybeValue: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.inputMaybeValue, (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.maybeValue, 'Maybe<T>')),
            constEnums: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.constEnums, false),
            enumsAsTypes: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.enumsAsTypes, false),
            futureProofEnums: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.futureProofEnums, false),
            futureProofUnions: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.futureProofUnions, false),
            enumsAsConst: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.enumsAsConst, false),
            numericEnums: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.numericEnums, false),
            onlyEnums: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.onlyEnums, false),
            onlyOperationTypes: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.onlyOperationTypes, false),
            immutableTypes: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.immutableTypes, false),
            useImplementingTypes: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.useImplementingTypes, false),
            entireFieldWrapperValue: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.entireFieldWrapperValue, 'T'),
            wrapEntireDefinitions: (0, visitor_plugin_common_1.getConfigValue)(pluginConfig.wrapEntireFieldDefinitions, false),
            ...additionalConfig,
        });
        (0, auto_bind_1.default)(this);
        const enumNames = Object.values(schema.getTypeMap())
            .filter(graphql_1.isEnumType)
            .map(type => type.name);
        this.setArgumentsTransformer(new typescript_variables_to_object_js_1.TypeScriptOperationVariablesToObject(this.scalars, this.convertName, this.config.avoidOptionals, this.config.immutableTypes, null, enumNames, pluginConfig.enumPrefix, pluginConfig.enumSuffix, this.config.enumValues, false, this.config.directiveArgumentAndInputFieldMappings, 'InputMaybe'));
        this.setDeclarationBlockConfig({
            enumNameValueSeparator: ' =',
            ignoreExport: this.config.noExport,
        });
    }
    _getTypeForNode(node, isVisitingInputType) {
        const typeAsString = node.name.value;
        if (this.config.useImplementingTypes) {
            const allTypesMap = this._schema.getTypeMap();
            const implementingTypes = [];
            // TODO: Move this to a better place, since we are using this logic in some other places as well.
            for (const graphqlType of Object.values(allTypesMap)) {
                if (graphqlType instanceof graphql_1.GraphQLObjectType) {
                    const allInterfaces = graphqlType.getInterfaces();
                    if (allInterfaces.some(int => typeAsString === int.name)) {
                        implementingTypes.push(this.convertName(graphqlType.name));
                    }
                }
            }
            if (implementingTypes.length > 0) {
                return implementingTypes.join(' | ');
            }
        }
        const typeString = super._getTypeForNode(node, isVisitingInputType);
        const schemaType = this._schema.getType(node.name.value);
        if ((0, graphql_1.isEnumType)(schemaType)) {
            // futureProofEnums + enumsAsTypes combination adds the future value to the enum type itself
            // so it's not necessary to repeat it in the usage
            const futureProofEnumUsageEnabled = this.config.futureProofEnums === true && this.config.enumsAsTypes !== true;
            if (futureProofEnumUsageEnabled && this.config.allowEnumStringTypes === true) {
                return `${typeString} | '%future added value' | ` + '`${' + typeString + '}`';
            }
            if (futureProofEnumUsageEnabled) {
                return `${typeString} | '%future added value'`;
            }
            if (this.config.allowEnumStringTypes === true) {
                return `${typeString} | ` + '`${' + typeString + '}`';
            }
        }
        return typeString;
    }
    getWrapperDefinitions() {
        if (this.config.onlyEnums)
            return [];
        const definitions = [this.getMaybeValue(), this.getInputMaybeValue()];
        if (this.config.wrapFieldDefinitions) {
            definitions.push(this.getFieldWrapperValue());
        }
        if (this.config.wrapEntireDefinitions) {
            definitions.push(this.getEntireFieldWrapperValue());
        }
        return definitions;
    }
    getMaybeValue() {
        return `${this.getExportPrefix()}type Maybe<T> = ${this.config.maybeValue};`;
    }
    getInputMaybeValue() {
        return `${this.getExportPrefix()}type InputMaybe<T> = ${this.config.inputMaybeValue};`;
    }
    clearOptional(str) {
        if (str.startsWith('Maybe')) {
            return str.replace(/Maybe<(.*?)>$/, '$1');
        }
        if (str.startsWith('InputMaybe')) {
            return str.replace(/InputMaybe<(.*?)>$/, '$1');
        }
        return str;
    }
    getExportPrefix() {
        if (this.config.noExport) {
            return '';
        }
        return super.getExportPrefix();
    }
    getMaybeWrapper(ancestors) {
        const currentVisitContext = this.getVisitorKindContextFromAncestors(ancestors);
        const isInputContext = currentVisitContext.includes(graphql_1.Kind.INPUT_OBJECT_TYPE_DEFINITION);
        return isInputContext ? 'InputMaybe' : 'Maybe';
    }
    NamedType(node, key, parent, path, ancestors) {
        return `${this.getMaybeWrapper(ancestors)}<${super.NamedType(node, key, parent, path, ancestors)}>`;
    }
    ListType(node, key, parent, path, ancestors) {
        return `${this.getMaybeWrapper(ancestors)}<${super.ListType(node, key, parent, path, ancestors)}>`;
    }
    UnionTypeDefinition(node, key, parent) {
        if (this.config.onlyOperationTypes || this.config.onlyEnums)
            return '';
        let withFutureAddedValue = [];
        if (this.config.futureProofUnions) {
            withFutureAddedValue = [
                this.config.immutableTypes
                    ? `{ readonly __typename?: "%other" }`
                    : `{ __typename?: "%other" }`,
            ];
        }
        const originalNode = parent[key];
        const possibleTypes = originalNode.types
            .map(t => this.scalars[t.name.value] ? this._getScalar(t.name.value, 'output') : this.convertName(t))
            .concat(...withFutureAddedValue)
            .join(' | ');
        return new visitor_plugin_common_1.DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind('type')
            .withName(this.convertName(node))
            .withComment(node.description?.value)
            .withContent(possibleTypes).string;
        // return super.UnionTypeDefinition(node, key, parent).concat(withFutureAddedValue).join("");
    }
    wrapWithListType(str) {
        return `${this.config.immutableTypes ? 'ReadonlyArray' : 'Array'}<${str}>`;
    }
    NonNullType(node) {
        const baseValue = super.NonNullType(node);
        return this.clearOptional(baseValue);
    }
    FieldDefinition(node, key, parent) {
        const typeString = this.config.wrapEntireDefinitions
            ? `EntireFieldWrapper<${node.type}>`
            : node.type;
        const originalFieldNode = parent[key];
        const addOptionalSign = !this.config.avoidOptionals.field && originalFieldNode.type.kind !== graphql_1.Kind.NON_NULL_TYPE;
        const comment = (0, visitor_plugin_common_1.getNodeComment)(node);
        const { type } = this.config.declarationKind;
        return (comment +
            (0, visitor_plugin_common_1.indent)(`${this.config.immutableTypes ? 'readonly ' : ''}${node.name.value}${addOptionalSign ? '?' : ''}: ${typeString}${this.getPunctuation(type)}`));
    }
    InputValueDefinition(node, key, parent, _path, ancestors) {
        const originalFieldNode = parent[key];
        const addOptionalSign = !this.config.avoidOptionals.inputValue &&
            (originalFieldNode.type.kind !== graphql_1.Kind.NON_NULL_TYPE ||
                (!this.config.avoidOptionals.defaultValue && node.defaultValue !== undefined));
        const comment = (0, visitor_plugin_common_1.getNodeComment)(node);
        const declarationKind = this.config.declarationKind.type;
        let type = node.type;
        if (node.directives && this.config.directiveArgumentAndInputFieldMappings) {
            type = this._getDirectiveOverrideType(node.directives) || type;
        }
        const readonlyPrefix = this.config.immutableTypes ? 'readonly ' : '';
        const buildFieldDefinition = (isOneOf = false) => {
            return `${readonlyPrefix}${node.name.value}${addOptionalSign && !isOneOf ? '?' : ''}: ${isOneOf ? this.clearOptional(type) : type}${this.getPunctuation(declarationKind)}`;
        };
        const realParentDef = ancestors?.[ancestors.length - 1];
        if (realParentDef) {
            const parentType = this._schema.getType(realParentDef.name.value);
            if ((0, visitor_plugin_common_1.isOneOfInputObjectType)(parentType)) {
                if (originalFieldNode.type.kind === graphql_1.Kind.NON_NULL_TYPE) {
                    throw new Error('Fields on an input object type can not be non-nullable. It seems like the schema was not validated.');
                }
                const fieldParts = [];
                for (const fieldName of Object.keys(parentType.getFields())) {
                    if (fieldName === node.name.value) {
                        fieldParts.push(buildFieldDefinition(true));
                        continue;
                    }
                    fieldParts.push(`${readonlyPrefix}${fieldName}?: never;`);
                }
                return comment + (0, visitor_plugin_common_1.indent)(`{ ${fieldParts.join(' ')} }`);
            }
        }
        return comment + (0, visitor_plugin_common_1.indent)(buildFieldDefinition());
    }
    EnumTypeDefinition(node) {
        const enumName = node.name.value;
        const outputType = (() => {
            if (this.config.enumsAsTypes) {
                return 'string-literal';
            }
            if (this.config.numericEnums) {
                return 'native-numeric';
            }
            if (this.config.enumsAsConst) {
                return 'const';
            }
            return this.config.constEnums ? 'native-const' : 'native';
        })();
        return (0, visitor_plugin_common_1.convertSchemaEnumToDeclarationBlockString)({
            schema: this._schema,
            node,
            declarationBlockConfig: this._declarationBlockConfig,
            enumName,
            enumValues: this.config.enumValues,
            futureProofEnums: this.config.futureProofEnums,
            ignoreEnumValuesFromSchema: this.config.ignoreEnumValuesFromSchema,
            outputType,
            naming: {
                convert: this.config.convert,
                options: {
                    typesPrefix: this.config.typesPrefix,
                    typesSuffix: this.config.typesSuffix,
                    useTypesPrefix: this.config.enumPrefix,
                    useTypesSuffix: this.config.enumSuffix,
                },
            },
        });
    }
    getPunctuation(_declarationKind) {
        return ';';
    }
}
exports.TsVisitor = TsVisitor;
