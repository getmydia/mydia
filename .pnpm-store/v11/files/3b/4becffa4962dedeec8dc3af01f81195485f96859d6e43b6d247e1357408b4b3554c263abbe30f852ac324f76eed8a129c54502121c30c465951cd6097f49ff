"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getFieldNames = exports.getFieldNodeNameValue = exports.REQUIRE_FIELDS_TYPE = exports.OMIT_TYPE = exports.DeclarationBlock = exports.getConfigValue = void 0;
exports.quoteIfNeeded = quoteIfNeeded;
exports.block = block;
exports.wrapWithSingleQuotes = wrapWithSingleQuotes;
exports.breakLine = breakLine;
exports.indent = indent;
exports.indentMultiline = indentMultiline;
exports.transformComment = transformComment;
exports.getBaseTypeNode = getBaseTypeNode;
exports.convertNameParts = convertNameParts;
exports.buildScalarsFromConfig = buildScalarsFromConfig;
exports.buildScalars = buildScalars;
exports.getRootTypeNames = getRootTypeNames;
exports.stripMapperTypeInterpolation = stripMapperTypeInterpolation;
exports.mergeSelectionSets = mergeSelectionSets;
exports.separateSelectionSet = separateSelectionSet;
exports.getPossibleTypes = getPossibleTypes;
exports.hasConditionalDirectives = hasConditionalDirectives;
exports.hasIncrementalDeliveryDirectives = hasIncrementalDeliveryDirectives;
exports.wrapTypeWithModifiers = wrapTypeWithModifiers;
exports.removeDescription = removeDescription;
exports.wrapTypeNodeWithModifiers = wrapTypeNodeWithModifiers;
exports.isOneOfInputObjectType = isOneOfInputObjectType;
exports.groupBy = groupBy;
exports.flatten = flatten;
exports.unique = unique;
const graphql_1 = require("graphql");
const mappers_js_1 = require("./mappers.js");
const scalars_js_1 = require("./scalars.js");
const getConfigValue = (value, defaultValue) => {
    if (value === null || value === undefined) {
        return defaultValue;
    }
    return value;
};
exports.getConfigValue = getConfigValue;
function quoteIfNeeded(array, joinWith = ' & ') {
    if (array.length === 0) {
        return '';
    }
    if (array.length === 1) {
        return array[0];
    }
    return `(${array.join(joinWith)})`;
}
function block(array) {
    return array && array.length !== 0 ? '{\n' + array.join('\n') + '\n}' : '';
}
function wrapWithSingleQuotes(value, skipNumericCheck = false) {
    if (skipNumericCheck) {
        if (typeof value === 'number') {
            return String(value);
        }
        return `'${value}'`;
    }
    if (typeof value === 'number' ||
        (typeof value === 'string' &&
            !Number.isNaN(parseInt(value)) &&
            parseFloat(value).toString() === value)) {
        return String(value);
    }
    return `'${value}'`;
}
function breakLine(str) {
    return str + '\n';
}
function indent(str, count = 1) {
    return new Array(count).fill('  ').join('') + str;
}
function indentMultiline(str, count = 1) {
    const indentation = new Array(count).fill('  ').join('');
    const replaceWith = '\n' + indentation;
    return indentation + str.replace(/\n/g, replaceWith);
}
function transformComment(comment, indentLevel = 0, disabled = false) {
    if (!comment || comment === '' || disabled) {
        return '';
    }
    if (isStringValueNode(comment)) {
        comment = comment.value;
    }
    comment = comment.split('*/').join('*\\/');
    let lines = comment.split('\n');
    if (lines.length === 1) {
        return indent(`/** ${lines[0]} */\n`, indentLevel);
    }
    lines = ['/**', ...lines.map(line => ` * ${line}`), ' */\n'];
    return stripTrailingSpaces(lines.map(line => indent(line, indentLevel)).join('\n'));
}
class DeclarationBlock {
    _config;
    _decorator = null;
    _export = false;
    _name = null;
    _kind = null;
    _methodName = null;
    _content = null;
    _block = null;
    _nameGenerics = null;
    _comment = null;
    _ignoreBlockWrapper = false;
    constructor(_config) {
        this._config = _config;
        this._config = {
            blockWrapper: '',
            blockTransformer: block => block,
            enumNameValueSeparator: ':',
            ...this._config,
        };
    }
    withDecorator(decorator) {
        this._decorator = decorator;
        return this;
    }
    export(exp = true) {
        if (!this._config.ignoreExport) {
            this._export = exp;
        }
        return this;
    }
    asKind(kind) {
        this._kind = kind;
        return this;
    }
    withComment(comment, disabled = false) {
        const nonEmptyComment = !!(isStringValueNode(comment) ? comment.value : comment);
        if (nonEmptyComment && !disabled) {
            this._comment = transformComment(comment, 0);
        }
        return this;
    }
    withMethodCall(methodName, ignoreBlockWrapper = false) {
        this._methodName = methodName;
        this._ignoreBlockWrapper = ignoreBlockWrapper;
        return this;
    }
    withBlock(block) {
        this._block = block;
        return this;
    }
    withContent(content) {
        this._content = content;
        return this;
    }
    withName(name, generics = null) {
        this._name = name;
        this._nameGenerics = generics;
        return this;
    }
    get string() {
        let result = '';
        if (this._decorator) {
            result += this._decorator + '\n';
        }
        if (this._export) {
            result += 'export ';
        }
        if (this._kind) {
            let extra = '';
            let name = '';
            if (['type', 'const', 'var', 'let'].includes(this._kind)) {
                extra = '= ';
            }
            if (this._name) {
                name = this._name + (this._nameGenerics || '') + ' ';
            }
            result += this._kind + ' ' + name + extra;
        }
        if (this._block) {
            if (this._content) {
                result += this._content;
            }
            const blockWrapper = this._ignoreBlockWrapper ? '' : this._config.blockWrapper;
            const before = '{' + blockWrapper;
            const after = blockWrapper + '}';
            const block = [before, this._block, after].filter(val => !!val).join('\n');
            if (this._methodName) {
                result += `${this._methodName}(${this._config.blockTransformer(block)})`;
            }
            else {
                result += this._config.blockTransformer(block);
            }
        }
        else if (this._content) {
            result += this._content;
        }
        else if (this._kind) {
            result += this._config.blockTransformer('{}');
        }
        return stripTrailingSpaces((this._comment || '') +
            result +
            (this._kind === 'interface' ||
                this._kind === 'enum' ||
                this._kind === 'namespace' ||
                this._kind === 'function'
                ? ''
                : ';') +
            '\n');
    }
}
exports.DeclarationBlock = DeclarationBlock;
function getBaseTypeNode(typeNode) {
    if (typeNode.kind === graphql_1.Kind.LIST_TYPE || typeNode.kind === graphql_1.Kind.NON_NULL_TYPE) {
        return getBaseTypeNode(typeNode.type);
    }
    return typeNode;
}
function convertNameParts(str, func, removeUnderscore = false) {
    if (removeUnderscore) {
        return func(str);
    }
    return str
        .split('_')
        .map(s => func(s))
        .join('_');
}
function buildScalarsFromConfig(schema, config, defaultScalarsMapping = scalars_js_1.DEFAULT_SCALARS, defaultScalarType = 'any') {
    return buildScalars(schema, config.scalars, defaultScalarsMapping, config.strictScalars ? null : config.defaultScalarType || defaultScalarType);
}
function buildScalars(schema, scalarsMapping, defaultScalarsMapping = scalars_js_1.DEFAULT_SCALARS, defaultScalarType = 'any') {
    const result = {};
    function normalizeScalarType(type) {
        if (typeof type === 'string') {
            return {
                input: type,
                output: type,
            };
        }
        return {
            input: type.input,
            output: type.output,
        };
    }
    for (const name of Object.keys(defaultScalarsMapping)) {
        result[name] = {
            input: (0, mappers_js_1.parseMapper)(defaultScalarsMapping[name].input),
            output: (0, mappers_js_1.parseMapper)(defaultScalarsMapping[name].output),
        };
    }
    if (schema) {
        const typeMap = schema.getTypeMap();
        Object.keys(typeMap)
            .map(typeName => typeMap[typeName])
            .filter(type => (0, graphql_1.isScalarType)(type))
            .map((scalarType) => {
            const { name } = scalarType;
            if (typeof scalarsMapping === 'string') {
                const inputMapper = (0, mappers_js_1.parseMapper)(scalarsMapping + '#' + name, name);
                if (inputMapper.isExternal) {
                    inputMapper.type += "['input']";
                }
                const outputMapper = (0, mappers_js_1.parseMapper)(scalarsMapping + '#' + name, name);
                if (outputMapper.isExternal) {
                    outputMapper.type += "['output']";
                }
                result[name] = {
                    input: inputMapper,
                    output: outputMapper,
                };
            }
            else if (scalarsMapping?.[name]) {
                const mappedScalar = scalarsMapping[name];
                if (typeof mappedScalar === 'string') {
                    const normalizedScalar = normalizeScalarType(scalarsMapping[name]);
                    result[name] = {
                        input: (0, mappers_js_1.parseMapper)(normalizedScalar.input, name),
                        output: (0, mappers_js_1.parseMapper)(normalizedScalar.output, name),
                    };
                }
                else if (typeof mappedScalar === 'object' &&
                    mappedScalar.input &&
                    mappedScalar.output) {
                    result[name] = {
                        input: (0, mappers_js_1.parseMapper)(mappedScalar.input, name),
                        output: (0, mappers_js_1.parseMapper)(mappedScalar.output, name),
                    };
                }
                else {
                    result[name] = {
                        input: {
                            isExternal: false,
                            type: JSON.stringify(mappedScalar),
                        },
                        output: {
                            isExternal: false,
                            type: JSON.stringify(mappedScalar),
                        },
                    };
                }
            }
            else if (scalarType.extensions?.codegenScalarType) {
                result[name] = {
                    input: {
                        isExternal: false,
                        type: scalarType.extensions.codegenScalarType,
                    },
                    output: {
                        isExternal: false,
                        type: scalarType.extensions.codegenScalarType,
                    },
                };
            }
            else if (!defaultScalarsMapping[name]) {
                if (defaultScalarType === null) {
                    throw new Error(`Unknown scalar type ${name}. Please override it using the "scalars" configuration field!`);
                }
                result[name] = {
                    input: {
                        isExternal: false,
                        type: defaultScalarType,
                    },
                    output: {
                        isExternal: false,
                        type: defaultScalarType,
                    },
                };
            }
        });
    }
    else if (scalarsMapping) {
        if (typeof scalarsMapping === 'string') {
            throw new Error('Cannot use string scalars mapping when building without a schema');
        }
        for (const name of Object.keys(scalarsMapping)) {
            if (typeof scalarsMapping[name] === 'string') {
                const normalizedScalar = normalizeScalarType(scalarsMapping[name]);
                result[name] = {
                    input: (0, mappers_js_1.parseMapper)(normalizedScalar.input, name),
                    output: (0, mappers_js_1.parseMapper)(normalizedScalar.output, name),
                };
            }
            else {
                const normalizedScalar = normalizeScalarType(scalarsMapping[name]);
                result[name] = {
                    input: {
                        isExternal: false,
                        type: JSON.stringify(normalizedScalar.input),
                    },
                    output: {
                        isExternal: false,
                        type: JSON.stringify(normalizedScalar.output),
                    },
                };
            }
        }
    }
    return result;
}
function isStringValueNode(node) {
    return node && typeof node === 'object' && node.kind === graphql_1.Kind.STRING;
}
// will be removed on next release because tools already has it
function getRootTypeNames(schema) {
    return [schema.getQueryType(), schema.getMutationType(), schema.getSubscriptionType()]
        .filter(t => t)
        .map(t => t.name);
}
function stripMapperTypeInterpolation(identifier) {
    return identifier.trim().replace(/<{.*}>/, '');
}
exports.OMIT_TYPE = 'export type Omit<T, K extends keyof T> = Pick<T, Exclude<keyof T, K>>;';
exports.REQUIRE_FIELDS_TYPE = `export type RequireFields<T, K extends keyof T> = Omit<T, K> & { [P in K]-?: NonNullable<T[P]> };`;
/**
 * merge selection sets into a new selection set without mutating the inputs.
 */
function mergeSelectionSets(selectionSet1, selectionSet2) {
    const newSelections = [...selectionSet1.selections];
    for (let selection2 of selectionSet2.selections) {
        if (selection2.kind === 'FragmentSpread' || selection2.kind === 'InlineFragment') {
            newSelections.push(selection2);
            continue;
        }
        if (selection2.kind !== 'Field') {
            throw new TypeError('Invalid state.');
        }
        const match = newSelections.find(selection1 => selection1.kind === 'Field' &&
            (0, exports.getFieldNodeNameValue)(selection1) === (0, exports.getFieldNodeNameValue)(selection2));
        if (match &&
            // recursively merge all selection sets
            match.kind === 'Field' &&
            match.selectionSet &&
            selection2.selectionSet) {
            selection2 = {
                ...selection2,
                selectionSet: mergeSelectionSets(match.selectionSet, selection2.selectionSet),
            };
        }
        newSelections.push(selection2);
    }
    return {
        kind: graphql_1.Kind.SELECTION_SET,
        selections: newSelections,
    };
}
const getFieldNodeNameValue = (node) => {
    return (node.alias || node.name).value;
};
exports.getFieldNodeNameValue = getFieldNodeNameValue;
function separateSelectionSet(selections) {
    return {
        fields: selections.filter(s => s.kind === graphql_1.Kind.FIELD),
        inlines: selections.filter(s => s.kind === graphql_1.Kind.INLINE_FRAGMENT),
        spreads: selections.filter(s => s.kind === graphql_1.Kind.FRAGMENT_SPREAD),
    };
}
function getPossibleTypes(schema, type) {
    if ((0, graphql_1.isListType)(type) || (0, graphql_1.isNonNullType)(type)) {
        return getPossibleTypes(schema, type.ofType);
    }
    if ((0, graphql_1.isObjectType)(type)) {
        return [type];
    }
    if ((0, graphql_1.isAbstractType)(type)) {
        return schema.getPossibleTypes(type);
    }
    return [];
}
function hasConditionalDirectives(field) {
    const CONDITIONAL_DIRECTIVES = ['skip', 'include'];
    return field.directives?.some(directive => CONDITIONAL_DIRECTIVES.includes(directive.name.value));
}
function hasIncrementalDeliveryDirectives(directives) {
    const INCREMENTAL_DELIVERY_DIRECTIVES = ['defer'];
    return directives?.some(directive => INCREMENTAL_DELIVERY_DIRECTIVES.includes(directive.name.value));
}
function wrapTypeWithModifiers(baseType, type, options) {
    let currentType = type;
    const modifiers = [];
    while (currentType) {
        if ((0, graphql_1.isNonNullType)(currentType)) {
            currentType = currentType.ofType;
        }
        else {
            modifiers.push(options.wrapOptional);
        }
        if ((0, graphql_1.isListType)(currentType)) {
            modifiers.push(options.wrapArray);
            currentType = currentType.ofType;
        }
        else {
            break;
        }
    }
    return modifiers.reduceRight((result, modifier) => modifier(result), baseType);
}
function removeDescription(nodes) {
    return nodes.map(node => ({ ...node, description: undefined }));
}
function wrapTypeNodeWithModifiers(baseType, typeNode) {
    switch (typeNode.kind) {
        case graphql_1.Kind.NAMED_TYPE: {
            return `Maybe<${baseType}>`;
        }
        case graphql_1.Kind.NON_NULL_TYPE: {
            const innerType = wrapTypeNodeWithModifiers(baseType, typeNode.type);
            return clearOptional(innerType);
        }
        case graphql_1.Kind.LIST_TYPE: {
            const innerType = wrapTypeNodeWithModifiers(baseType, typeNode.type);
            return `Maybe<Array<${innerType}>>`;
        }
    }
}
function clearOptional(str) {
    const rgx = new RegExp(`^Maybe<(.*?)>$`, 'i');
    if (str.startsWith(`Maybe`)) {
        return str.replace(rgx, '$1');
    }
    return str;
}
function stripTrailingSpaces(str) {
    return str.replace(/ +\n/g, '\n');
}
const isOneOfTypeCache = new WeakMap();
function isOneOfInputObjectType(namedType) {
    if (!namedType) {
        return false;
    }
    let isOneOfType = isOneOfTypeCache.get(namedType);
    if (isOneOfType !== undefined) {
        return isOneOfType;
    }
    isOneOfType =
        (0, graphql_1.isInputObjectType)(namedType) &&
            (namedType.isOneOf ||
                namedType.astNode?.directives?.some(d => d.name.value === 'oneOf'));
    isOneOfTypeCache.set(namedType, isOneOfType);
    return isOneOfType;
}
function groupBy(array, key) {
    return array.reduce((acc, item) => {
        const group = (acc[key(item)] ??= []);
        group.push(item);
        return acc;
    }, {});
}
function flatten(array) {
    return [].concat(...array);
}
function unique(array, key = item => item.toString()) {
    return Object.values(array.reduce((acc, item) => ({ [key(item)]: item, ...acc }), {}));
}
function getFullPathFieldName(selection, parentName) {
    const fullName = 'alias' in selection && selection.alias
        ? `${selection.alias.value}@${selection.name.value}`
        : selection.name.value;
    return parentName ? `${parentName}.${fullName}` : fullName;
}
const getFieldNames = ({ selections, fieldNames = new Set(), parentName = '', loadedFragments, }) => {
    for (const selection of selections) {
        switch (selection.kind) {
            case graphql_1.Kind.FIELD: {
                const fieldName = getFullPathFieldName(selection, parentName);
                fieldNames.add(fieldName);
                if (selection.selectionSet) {
                    (0, exports.getFieldNames)({
                        selections: selection.selectionSet.selections,
                        fieldNames,
                        parentName: fieldName,
                        loadedFragments,
                    });
                }
                break;
            }
            case graphql_1.Kind.FRAGMENT_SPREAD: {
                (0, exports.getFieldNames)({
                    selections: loadedFragments
                        .filter(def => def.name === selection.name.value)
                        .flatMap(s => s.node.selectionSet.selections),
                    fieldNames,
                    parentName,
                    loadedFragments,
                });
                break;
            }
            case graphql_1.Kind.INLINE_FRAGMENT: {
                (0, exports.getFieldNames)({
                    selections: selection.selectionSet.selections,
                    fieldNames,
                    parentName,
                    loadedFragments,
                });
                break;
            }
        }
    }
    return fieldNames;
};
exports.getFieldNames = getFieldNames;
