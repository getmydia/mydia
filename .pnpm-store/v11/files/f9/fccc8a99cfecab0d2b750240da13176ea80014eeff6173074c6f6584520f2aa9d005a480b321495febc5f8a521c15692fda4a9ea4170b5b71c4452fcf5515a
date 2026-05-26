"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.normalizeOperationAvoidOptionals = void 0;
const normalizeOperationAvoidOptionals = (avoidOptionals) => {
    const defaultAvoidOptionals = {
        variableValue: false,
        inputValue: false,
        defaultValue: false,
    };
    if (typeof avoidOptionals === 'boolean') {
        return {
            variableValue: avoidOptionals,
            inputValue: avoidOptionals,
            defaultValue: avoidOptionals,
        };
    }
    return {
        ...defaultAvoidOptionals,
        ...avoidOptionals,
    };
};
exports.normalizeOperationAvoidOptionals = normalizeOperationAvoidOptionals;
