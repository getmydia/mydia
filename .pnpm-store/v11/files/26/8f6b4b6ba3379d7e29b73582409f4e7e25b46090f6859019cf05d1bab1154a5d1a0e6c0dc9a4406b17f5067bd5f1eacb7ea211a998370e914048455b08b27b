"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.pick = pick;
exports.isSchemaText = isSchemaText;
exports.isWrappedSchemaJson = isWrappedSchemaJson;
exports.isSchemaJson = isSchemaJson;
exports.isSchemaAst = isSchemaAst;
/**
 * @internal
 */
function pick(obj, keys) {
    for (const key of keys) {
        if (obj[key]) {
            return obj[key];
        }
    }
    return obj;
}
// checkers
/**
 * @internal
 */
function isSchemaText(obj) {
    return typeof obj === 'string';
}
/**
 * @internal
 */
function isWrappedSchemaJson(obj) {
    const json = obj;
    return json.data !== undefined && json.data.__schema !== undefined;
}
/**
 * @internal
 */
function isSchemaJson(obj) {
    const json = obj;
    return json !== undefined && json.__schema !== undefined;
}
/**
 * @internal
 */
function isSchemaAst(obj) {
    return obj.kind !== undefined;
}
