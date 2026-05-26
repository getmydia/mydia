import { isEnumType, Kind, } from 'graphql';
import { BaseVisitor } from './base-visitor.js';
import { buildEnumValuesBlock } from './convert-schema-enum-to-declaration-block-string.js';
import { normalizeDeclarationKind } from './declaration-kinds.js';
import { parseEnumValues } from './enum-values.js';
import { buildTypeImport, getEnumsImports } from './imports.js';
import { transformDirectiveArgumentAndInputFieldMappings } from './mappers.js';
import { DEFAULT_SCALARS } from './scalars.js';
import { buildScalarsFromConfig, DeclarationBlock, getConfigValue, getNodeComment, indent, isOneOfInputObjectType, transformComment, wrapWithSingleQuotes, } from './utils.js';
import { OperationVariablesToObject } from './variables-to-object.js';
export class BaseTypesVisitor extends BaseVisitor {
    _schema;
    _argumentsTransformer;
    constructor(_schema, rawConfig, additionalConfig, defaultScalars = DEFAULT_SCALARS) {
        super(rawConfig, {
            onlyEnums: getConfigValue(rawConfig.onlyEnums, false),
            onlyOperationTypes: getConfigValue(rawConfig.onlyOperationTypes, false),
            addUnderscoreToArgsType: getConfigValue(rawConfig.addUnderscoreToArgsType, false),
            ignoreEnumValuesFromSchema: getConfigValue(rawConfig.ignoreEnumValuesFromSchema, false),
            declarationKind: normalizeDeclarationKind(rawConfig.declarationKind),
            scalars: buildScalarsFromConfig(_schema, rawConfig, defaultScalars),
            fieldWrapperValue: getConfigValue(rawConfig.fieldWrapperValue, 'T'),
            wrapFieldDefinitions: getConfigValue(rawConfig.wrapFieldDefinitions, false),
            entireFieldWrapperValue: getConfigValue(rawConfig.entireFieldWrapperValue, 'T'),
            wrapEntireDefinitions: getConfigValue(rawConfig.wrapEntireFieldDefinitions, false),
            directiveArgumentAndInputFieldMappings: transformDirectiveArgumentAndInputFieldMappings(rawConfig.directiveArgumentAndInputFieldMappings ?? {}, rawConfig.directiveArgumentAndInputFieldMappingTypeSuffix),
            addTypename: !rawConfig.skipTypename,
            nonOptionalTypename: getConfigValue(rawConfig.nonOptionalTypename, false),
            ...additionalConfig,
        });
        this._schema = _schema;
        this.config.enumValues = parseEnumValues({
            schema: _schema,
            mapOrStr: rawConfig.enumValues,
            ignoreEnumValuesFromSchema: this.config.ignoreEnumValuesFromSchema,
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
        // Note: Missing directive mappers but not a problem since always overriden by implementors
        this._argumentsTransformer = new OperationVariablesToObject(this.scalars, this.convertName);
    }
    getExportPrefix() {
        return 'export ';
    }
    getFieldWrapperValue() {
        if (this.config.fieldWrapperValue) {
            return `${this.getExportPrefix()}type FieldWrapper<T> = ${this.config.fieldWrapperValue};`;
        }
        return '';
    }
    getEntireFieldWrapperValue() {
        if (this.config.entireFieldWrapperValue) {
            return `${this.getExportPrefix()}type EntireFieldWrapper<T> = ${this.config.entireFieldWrapperValue};`;
        }
        return '';
    }
    getScalarsImports() {
        return Object.keys(this.config.scalars).reduce((res, enumName) => {
            const mappedValue = this.config.scalars[enumName];
            if (mappedValue.input.isExternal) {
                res.push(buildTypeImport({
                    identifier: mappedValue.input.import,
                    source: mappedValue.input.source,
                    asDefault: mappedValue.input.default,
                    useTypeImports: this.config.useTypeImports,
                }));
            }
            if (mappedValue.output.isExternal) {
                res.push(buildTypeImport({
                    identifier: mappedValue.output.import,
                    source: mappedValue.output.source,
                    asDefault: mappedValue.output.default,
                    useTypeImports: this.config.useTypeImports,
                }));
            }
            return res;
        }, []);
    }
    getDirectiveArgumentAndInputFieldMappingsImports() {
        return Object.keys(this.config.directiveArgumentAndInputFieldMappings)
            .map(directive => {
            const mappedValue = this.config.directiveArgumentAndInputFieldMappings[directive];
            if (mappedValue.isExternal) {
                return buildTypeImport({
                    identifier: mappedValue.import,
                    source: mappedValue.source,
                    asDefault: mappedValue.default,
                    useTypeImports: this.config.useTypeImports,
                });
            }
            return null;
        })
            .filter(a => a);
    }
    get scalarsDefinition() {
        if (this.config.onlyEnums)
            return '';
        const allScalars = Object.keys(this.config.scalars).map(scalarName => {
            const inputScalarValue = this.config.scalars[scalarName].input.type;
            const outputScalarValue = this.config.scalars[scalarName].output.type;
            const scalarType = this._schema.getType(scalarName);
            const comment = scalarType?.astNode && scalarType.description
                ? transformComment(scalarType.description, 1)
                : '';
            const { scalar } = this._parsedConfig.declarationKind;
            return (comment +
                indent(`${scalarName}: { input: ${inputScalarValue}${this.getPunctuation(scalar)} output: ${outputScalarValue}${this.getPunctuation(scalar)} }`));
        });
        return new DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind(this._parsedConfig.declarationKind.scalar)
            .withName('Scalars')
            .withComment('All built-in and custom scalars, mapped to their actual values')
            .withBlock(allScalars.join('\n')).string;
    }
    get directiveArgumentAndInputFieldMappingsDefinition() {
        const directiveEntries = Object.entries(this.config.directiveArgumentAndInputFieldMappings);
        if (directiveEntries.length === 0) {
            return '';
        }
        const allDirectives = [];
        for (const [directiveName, parsedMapper] of directiveEntries) {
            const directiveType = this._schema.getDirective(directiveName);
            const comment = directiveType?.astNode && directiveType.description
                ? transformComment(directiveType.description, 1)
                : '';
            const { directive } = this._parsedConfig.declarationKind;
            allDirectives.push(comment + indent(`${directiveName}: ${parsedMapper.type}${this.getPunctuation(directive)}`));
        }
        return new DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind(this._parsedConfig.declarationKind.directive)
            .withName('DirectiveArgumentAndInputFieldMappings')
            .withComment('Type overrides using directives')
            .withBlock(allDirectives.join('\n')).string;
    }
    setDeclarationBlockConfig(config) {
        this._declarationBlockConfig = config;
    }
    setArgumentsTransformer(argumentsTransfomer) {
        this._argumentsTransformer = argumentsTransfomer;
    }
    NonNullType(node) {
        const asString = node.type;
        return asString;
    }
    getInputObjectDeclarationBlock(node) {
        return new DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind(this._parsedConfig.declarationKind.input)
            .withName(this.convertName(node))
            .withComment(node.description?.value)
            .withBlock(node.fields.join('\n'));
    }
    getInputObjectOneOfDeclarationBlock(node) {
        // As multiple fields always result in a union, we have
        // to force a declaration kind of `type` in this case
        const declarationKind = node.fields.length === 1 ? this._parsedConfig.declarationKind.input : 'type';
        return new DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind(declarationKind)
            .withName(this.convertName(node))
            .withComment(node.description?.value)
            .withContent(`\n` + node.fields.join('\n  |'));
    }
    InputObjectTypeDefinition(node) {
        if (this.config.onlyEnums)
            return '';
        if (isOneOfInputObjectType(this._schema.getType(node.name.value))) {
            return this.getInputObjectOneOfDeclarationBlock(node).string;
        }
        return this.getInputObjectDeclarationBlock(node).string;
    }
    InputValueDefinition(node) {
        if (this.config.onlyEnums)
            return '';
        const comment = transformComment(node.description.value, 1);
        const { input } = this._parsedConfig.declarationKind;
        let type = node.type;
        if (node.directives && this.config.directiveArgumentAndInputFieldMappings) {
            type = this._getDirectiveOverrideType(node.directives) || type;
        }
        return comment + indent(`${node.name.value}: ${type}${this.getPunctuation(input)}`);
    }
    FieldDefinition(node) {
        if (this.config.onlyEnums)
            return '';
        const typeString = node.type;
        const { type } = this._parsedConfig.declarationKind;
        const comment = getNodeComment(node);
        return comment + indent(`${node.name.value}: ${typeString}${this.getPunctuation(type)}`);
    }
    UnionTypeDefinition(node, key, parent) {
        if (this.config.onlyOperationTypes || this.config.onlyEnums)
            return '';
        const originalNode = parent[key];
        const possibleTypes = originalNode.types
            .map(t => this.scalars[t.name.value] ? this._getScalar(t.name.value, 'output') : this.convertName(t))
            .join(' | ');
        return new DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind('type')
            .withName(this.convertName(node))
            .withComment(node.description.value)
            .withContent(possibleTypes).string;
    }
    mergeInterfaces(interfaces, hasOtherFields) {
        return interfaces.join(' & ') + (interfaces.length && hasOtherFields ? ' & ' : '');
    }
    appendInterfacesAndFieldsToBlock(block, interfaces, fields) {
        block.withContent(this.mergeInterfaces(interfaces, fields.length > 0));
        block.withBlock(this.mergeAllFields(fields, interfaces.length > 0));
    }
    getObjectTypeDeclarationBlock(node, originalNode) {
        const optionalTypename = this.config.nonOptionalTypename ? '__typename' : '__typename?';
        const { type, interface: interfacesType } = this._parsedConfig.declarationKind;
        const allFields = [
            ...(this.config.addTypename
                ? [
                    indent(`${this.config.immutableTypes ? 'readonly ' : ''}${optionalTypename}: '${node.name.value}'${this.getPunctuation(type)}`),
                ]
                : []),
            ...node.fields,
        ];
        const interfacesNames = originalNode.interfaces
            ? originalNode.interfaces.map(i => this.convertName(i))
            : [];
        const declarationBlock = new DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind(type)
            .withName(this.convertName(node))
            .withComment(node.description?.value);
        if (type === 'interface' || type === 'class') {
            if (interfacesNames.length > 0) {
                const keyword = interfacesType === 'interface' && type === 'class' ? 'implements' : 'extends';
                declarationBlock.withContent(`${keyword} ` + interfacesNames.join(', ') + (allFields.length > 0 ? ' ' : ' {}'));
            }
            declarationBlock.withBlock(this.mergeAllFields(allFields, false));
        }
        else {
            this.appendInterfacesAndFieldsToBlock(declarationBlock, interfacesNames, allFields);
        }
        return declarationBlock;
    }
    mergeAllFields(allFields, _hasInterfaces) {
        return allFields.join('\n');
    }
    ObjectTypeDefinition(node, key, parent) {
        if (this.config.onlyOperationTypes || this.config.onlyEnums)
            return '';
        const originalNode = parent[key];
        return [
            this.getObjectTypeDeclarationBlock(node, originalNode).string,
            this.buildArgumentsBlock(originalNode),
        ]
            .filter(f => f)
            .join('\n\n');
    }
    getInterfaceTypeDeclarationBlock(node, _originalNode) {
        const declarationBlock = new DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind(this._parsedConfig.declarationKind.interface)
            .withName(this.convertName(node))
            .withComment(node.description?.value);
        return declarationBlock.withBlock(node.fields.join('\n'));
    }
    InterfaceTypeDefinition(node, key, parent) {
        if (this.config.onlyOperationTypes || this.config.onlyEnums)
            return '';
        const originalNode = parent[key];
        return [
            this.getInterfaceTypeDeclarationBlock(node, originalNode).string,
            this.buildArgumentsBlock(originalNode),
        ]
            .filter(f => f)
            .join('\n\n');
    }
    ScalarTypeDefinition(_node) {
        // We empty this because we handle scalars in a different way, see constructor.
        return '';
    }
    getEnumsImports() {
        return getEnumsImports({
            enumValues: this.config.enumValues,
            useTypeImports: this.config.useTypeImports,
        });
    }
    EnumTypeDefinition(node) {
        const enumName = node.name.value;
        // In case of mapped external enum string
        if (this.config.enumValues[enumName]?.sourceFile) {
            return null;
        }
        return new DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind('enum')
            .withName(this.convertName(node, {
            useTypesPrefix: this.config.enumPrefix,
            useTypesSuffix: this.config.enumSuffix,
        }))
            .withComment(node.description.value)
            .withBlock(buildEnumValuesBlock({
            typeName: enumName,
            values: node.values,
            schema: this._schema,
            naming: {
                convert: this.config.convert,
                options: {
                    typesPrefix: this.config.typesPrefix,
                    useTypesPrefix: this.config.enumPrefix,
                    typesSuffix: this.config.typesSuffix,
                    useTypesSuffix: this.config.enumSuffix,
                },
            },
            ignoreEnumValuesFromSchema: this.config.ignoreEnumValuesFromSchema,
            declarationBlockConfig: this._declarationBlockConfig,
            enumValues: this.config.enumValues,
        })).string;
    }
    makeValidEnumIdentifier(identifier) {
        if (/^[0-9]/.exec(identifier)) {
            return wrapWithSingleQuotes(identifier, true);
        }
        return identifier;
    }
    DirectiveDefinition(_node) {
        return '';
    }
    getArgumentsObjectDeclarationBlock(node, name, field) {
        return new DeclarationBlock(this._declarationBlockConfig)
            .export()
            .asKind(this._parsedConfig.declarationKind.arguments)
            .withName(this.convertName(name))
            .withComment(node.description?.value)
            .withBlock(this._argumentsTransformer.transform(field.arguments));
    }
    getArgumentsObjectTypeDefinition(node, name, field) {
        if (this.config.onlyEnums)
            return '';
        return this.getArgumentsObjectDeclarationBlock(node, name, field).string;
    }
    buildArgumentsBlock(node) {
        const fieldsWithArguments = node.fields.filter(field => field.arguments && field.arguments.length > 0) || [];
        return fieldsWithArguments
            .map(field => {
            const name = node.name.value +
                (this.config.addUnderscoreToArgsType ? '_' : '') +
                this.convertName(field, {
                    useTypesPrefix: false,
                    useTypesSuffix: false,
                }) +
                'Args';
            return this.getArgumentsObjectTypeDefinition(node, name, field);
        })
            .join('\n\n');
    }
    _getScalar(name, type) {
        return `Scalars['${name}']['${type}']`;
    }
    _getDirectiveArgumentNadInputFieldMapping(name) {
        return `DirectiveArgumentAndInputFieldMappings['${name}']`;
    }
    _getDirectiveOverrideType(directives) {
        const type = directives
            .map(directive => {
            const directiveName = directive.name.value;
            if (this.config.directiveArgumentAndInputFieldMappings[directiveName]) {
                return this._getDirectiveArgumentNadInputFieldMapping(directiveName);
            }
            return null;
        })
            .reverse()
            .find(a => !!a);
        return type || null;
    }
    _getTypeForNode(node, isVisitingInputType) {
        const typeAsString = node.name.value;
        if (this.scalars[typeAsString]) {
            return this._getScalar(typeAsString, isVisitingInputType ? 'input' : 'output');
        }
        if (this.config.enumValues[typeAsString]) {
            return this.config.enumValues[typeAsString].typeIdentifierConverted;
        }
        const schemaType = this._schema.getType(typeAsString);
        if (schemaType && isEnumType(schemaType)) {
            return this.convertName(node, {
                useTypesPrefix: this.config.enumPrefix,
                useTypesSuffix: this.config.enumSuffix,
            });
        }
        return this.convertName(node);
    }
    NamedType(node, key, parent, path, ancestors) {
        const currentVisitContext = this.getVisitorKindContextFromAncestors(ancestors);
        const isVisitingInputType = currentVisitContext.includes(Kind.INPUT_OBJECT_TYPE_DEFINITION);
        const typeToUse = this._getTypeForNode(node, isVisitingInputType);
        if (!isVisitingInputType && this.config.fieldWrapperValue && this.config.wrapFieldDefinitions) {
            return `FieldWrapper<${typeToUse}>`;
        }
        return typeToUse;
    }
    ListType(node, _key, _parent, _path, _ancestors) {
        const asString = node.type;
        return this.wrapWithListType(asString);
    }
    SchemaDefinition() {
        return null;
    }
    SchemaExtension() {
        return null;
    }
    wrapWithListType(str) {
        return `Array<${str}>`;
    }
}
