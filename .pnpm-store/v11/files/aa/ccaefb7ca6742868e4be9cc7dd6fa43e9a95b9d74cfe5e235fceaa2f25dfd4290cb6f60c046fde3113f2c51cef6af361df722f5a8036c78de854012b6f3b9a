import { isAbstractType, isInputObjectType, isListType, isNonNullType, isObjectType, isScalarType, Kind, } from 'graphql';
import { parseMapper } from './mappers.js';
import { DEFAULT_SCALARS } from './scalars.js';
export const getConfigValue = (value, defaultValue) => {
    if (value === null || value === undefined) {
        return defaultValue;
    }
    return value;
};
export function quoteIfNeeded(array, joinWith = ' & ') {
    if (array.length === 0) {
        return '';
    }
    if (array.length === 1) {
        return array[0];
    }
    return `(${array.join(joinWith)})`;
}
export function block(array) {
    return array && array.length !== 0 ? '{\n' + array.join('\n') + '\n}' : '';
}
export function wrapWithSingleQuotes(value, skipNumericCheck = false) {
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
export function breakLine(str) {
    return str + '\n';
}
export function indent(str, count = 1) {
    return new Array(count).fill('  ').join('') + str;
}
export function indentMultiline(str, count = 1) {
    const indentation = new Array(count).fill('  ').join('');
    const replaceWith = '\n' + indentation;
    return indentation + str.replace(/\n/g, replaceWith);
}
export function transformComment(comment, indentLevel = 0, disabled = false) {
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
export class DeclarationBlock {
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
export function getBaseTypeNode(typeNode) {
    if (typeNode.kind === Kind.LIST_TYPE || typeNode.kind === Kind.NON_NULL_TYPE) {
        return getBaseTypeNode(typeNode.type);
    }
    return typeNode;
}
export function convertNameParts(str, func, removeUnderscore = false) {
    if (removeUnderscore) {
        return func(str);
    }
    return str
        .split('_')
        .map(s => func(s))
        .join('_');
}
export function buildScalarsFromConfig(schema, config, defaultScalarsMapping = DEFAULT_SCALARS, defaultScalarType = 'any') {
    return buildScalars(schema, config.scalars, defaultScalarsMapping, config.strictScalars ? null : config.defaultScalarType || defaultScalarType);
}
export function buildScalars(schema, scalarsMapping, defaultScalarsMapping = DEFAULT_SCALARS, defaultScalarType = 'any') {
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
            input: parseMapper(defaultScalarsMapping[name].input),
            output: parseMapper(defaultScalarsMapping[name].output),
        };
    }
    if (schema) {
        const typeMap = schema.getTypeMap();
        Object.keys(typeMap)
            .map(typeName => typeMap[typeName])
            .filter(type => isScalarType(type))
            .map((scalarType) => {
            const { name } = scalarType;
            if (typeof scalarsMapping === 'string') {
                const inputMapper = parseMapper(scalarsMapping + '#' + name, name);
                if (inputMapper.isExternal) {
                    inputMapper.type += "['input']";
                }
                const outputMapper = parseMapper(scalarsMapping + '#' + name, name);
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
                        input: parseMapper(normalizedScalar.input, name),
                        output: parseMapper(normalizedScalar.output, name),
                    };
                }
                else if (typeof mappedScalar === 'object' &&
                    mappedScalar.input &&
                    mappedScalar.output) {
                    result[name] = {
                        input: parseMapper(mappedScalar.input, name),
                        output: parseMapper(mappedScalar.output, name),
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
                    input: parseMapper(normalizedScalar.input, name),
                    output: parseMapper(normalizedScalar.output, name),
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
    return node && typeof node === 'object' && node.kind === Kind.STRING;
}
// will be removed on next release because tools already has it
export function getRootTypeNames(schema) {
    return [schema.getQueryType(), schema.getMutationType(), schema.getSubscriptionType()]
        .filter(t => t)
        .map(t => t.name);
}
export function stripMapperTypeInterpolation(identifier) {
    return identifier.trim().replace(/<{.*}>/, '');
}
export const OMIT_TYPE = 'export type Omit<T, K extends keyof T> = Pick<T, Exclude<keyof T, K>>;';
export const REQUIRE_FIELDS_TYPE = `export type RequireFields<T, K extends keyof T> = Omit<T, K> & { [P in K]-?: NonNullable<T[P]> };`;
/**
 * merge selection sets into a new selection set without mutating the inputs.
 */
export function mergeSelectionSets(selectionSet1, selectionSet2) {
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
            getFieldNodeNameValue(selection1) === getFieldNodeNameValue(selection2));
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
        kind: Kind.SELECTION_SET,
        selections: newSelections,
    };
}
export const getFieldNodeNameValue = (node) => {
    return (node.alias || node.name).value;
};
export function separateSelectionSet(selections) {
    return {
        fields: selections.filter(s => s.kind === Kind.FIELD),
        inlines: selections.filter(s => s.kind === Kind.INLINE_FRAGMENT),
        spreads: selections.filter(s => s.kind === Kind.FRAGMENT_SPREAD),
    };
}
export function getPossibleTypes(schema, type) {
    if (isListType(type) || isNonNullType(type)) {
        return getPossibleTypes(schema, type.ofType);
    }
    if (isObjectType(type)) {
        return [type];
    }
    if (isAbstractType(type)) {
        return schema.getPossibleTypes(type);
    }
    return [];
}
export function hasConditionalDirectives(field) {
    const CONDITIONAL_DIRECTIVES = ['skip', 'include'];
    return field.directives?.some(directive => CONDITIONAL_DIRECTIVES.includes(directive.name.value));
}
export function hasIncrementalDeliveryDirectives(directives) {
    const INCREMENTAL_DELIVERY_DIRECTIVES = ['defer'];
    return directives?.some(directive => INCREMENTAL_DELIVERY_DIRECTIVES.includes(directive.name.value));
}
export function wrapTypeWithModifiers(baseType, type, options) {
    let currentType = type;
    const modifiers = [];
    while (currentType) {
        if (isNonNullType(currentType)) {
            currentType = currentType.ofType;
        }
        else {
            modifiers.push(options.wrapOptional);
        }
        if (isListType(currentType)) {
            modifiers.push(options.wrapArray);
            currentType = currentType.ofType;
        }
        else {
            break;
        }
    }
    return modifiers.reduceRight((result, modifier) => modifier(result), baseType);
}
export function removeDescription(nodes) {
    return nodes.map(node => ({ ...node, description: undefined }));
}
export function wrapTypeNodeWithModifiers(baseType, typeNode) {
    switch (typeNode.kind) {
        case Kind.NAMED_TYPE: {
            return `Maybe<${baseType}>`;
        }
        case Kind.NON_NULL_TYPE: {
            const innerType = wrapTypeNodeWithModifiers(baseType, typeNode.type);
            return clearOptional(innerType);
        }
        case Kind.LIST_TYPE: {
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
export function isOneOfInputObjectType(namedType) {
    if (!namedType) {
        return false;
    }
    let isOneOfType = isOneOfTypeCache.get(namedType);
    if (isOneOfType !== undefined) {
        return isOneOfType;
    }
    isOneOfType =
        isInputObjectType(namedType) &&
            (namedType.isOneOf ||
                namedType.astNode?.directives?.some(d => d.name.value === 'oneOf'));
    isOneOfTypeCache.set(namedType, isOneOfType);
    return isOneOfType;
}
export function groupBy(array, key) {
    return array.reduce((acc, item) => {
        const group = (acc[key(item)] ??= []);
        group.push(item);
        return acc;
    }, {});
}
export function flatten(array) {
    return [].concat(...array);
}
export function unique(array, key = item => item.toString()) {
    return Object.values(array.reduce((acc, item) => ({ [key(item)]: item, ...acc }), {}));
}
function getFullPathFieldName(selection, parentName) {
    const fullName = 'alias' in selection && selection.alias
        ? `${selection.alias.value}@${selection.name.value}`
        : selection.name.value;
    return parentName ? `${parentName}.${fullName}` : fullName;
}
export const getFieldNames = ({ selections, fieldNames = new Set(), parentName = '', loadedFragments, }) => {
    for (const selection of selections) {
        switch (selection.kind) {
            case Kind.FIELD: {
                const fieldName = getFullPathFieldName(selection, parentName);
                fieldNames.add(fieldName);
                if (selection.selectionSet) {
                    getFieldNames({
                        selections: selection.selectionSet.selections,
                        fieldNames,
                        parentName: fieldName,
                        loadedFragments,
                    });
                }
                break;
            }
            case Kind.FRAGMENT_SPREAD: {
                getFieldNames({
                    selections: loadedFragments
                        .filter(def => def.name === selection.name.value)
                        .flatMap(s => s.node.selectionSet.selections),
                    fieldNames,
                    parentName,
                    loadedFragments,
                });
                break;
            }
            case Kind.INLINE_FRAGMENT: {
                getFieldNames({
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
