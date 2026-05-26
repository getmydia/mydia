const DEFAULT_OPERATION_DECLARATION_KINDS = {
    input: 'type',
    result: 'type',
};
export function normalizeOperationDeclarationKind(declarationKind) {
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
