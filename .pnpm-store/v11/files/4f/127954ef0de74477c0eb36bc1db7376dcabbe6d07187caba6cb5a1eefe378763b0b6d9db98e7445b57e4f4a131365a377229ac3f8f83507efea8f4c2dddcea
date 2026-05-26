"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.mergeOutputs = mergeOutputs;
exports.isWrapperType = isWrapperType;
exports.getBaseType = getBaseType;
exports.removeNonNullWrapper = removeNonNullWrapper;
const graphql_1 = require("graphql");
function mergeOutputs(content) {
    const result = {
        content: '',
        prepend: [],
        append: [],
    };
    if (Array.isArray(content)) {
        for (const item of content) {
            if (typeof item === 'string') {
                result.content += item;
            }
            else {
                result.content += item.content;
                result.prepend.push(...(item.prepend || []));
                result.append.push(...(item.append || []));
            }
        }
    }
    return [...result.prepend, result.content, ...result.append].join('\n');
}
function isWrapperType(t) {
    return (0, graphql_1.isListType)(t) || (0, graphql_1.isNonNullType)(t);
}
function getBaseType(type) {
    if (isWrapperType(type)) {
        return getBaseType(type.ofType);
    }
    return type;
}
function removeNonNullWrapper(type) {
    return (0, graphql_1.isNonNullType)(type) ? type.ofType : type;
}
