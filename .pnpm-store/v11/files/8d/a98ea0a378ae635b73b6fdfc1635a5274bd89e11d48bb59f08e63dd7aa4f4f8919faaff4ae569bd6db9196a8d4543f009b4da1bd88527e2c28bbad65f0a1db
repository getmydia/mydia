"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.normalizeOperationDeclarationKind = normalizeOperationDeclarationKind;
const DEFAULT_OPERATION_DECLARATION_KINDS = {
    input: 'type',
    result: 'type',
};
function normalizeOperationDeclarationKind(declarationKind) {
    if (typeof declarationKind === 'string') {
        return {
            input: declarationKind,
            result: declarationKind,
        };
    }
    return {
        ...DEFAULT_OPERATION_DECLARATION_KINDS,
        ...declarationKind,
    };
}
