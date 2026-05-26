"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.DEFAULT_AVOID_OPTIONALS = void 0;
exports.normalizeAvoidOptionals = normalizeAvoidOptionals;
exports.DEFAULT_AVOID_OPTIONALS = {
    object: false,
    inputValue: false,
    field: false,
    defaultValue: false,
    resolvers: false,
    query: false,
    mutation: false,
    subscription: false,
};
function normalizeAvoidOptionals(avoidOptionals) {
    if (typeof avoidOptionals === 'boolean') {
        return {
            object: avoidOptionals,
            inputValue: avoidOptionals,
            field: avoidOptionals,
            defaultValue: avoidOptionals,
            resolvers: avoidOptionals,
            query: avoidOptionals,
            mutation: avoidOptionals,
            subscription: avoidOptionals,
        };
    }
    return {
        ...exports.DEFAULT_AVOID_OPTIONALS,
        ...avoidOptionals,
    };
}
