export class BaseSelectionSetProcessor {
    config;
    typeCache = new Map();
    constructor(config) {
        this.config = config;
    }
    buildFieldsIntoObject(allObjectsMerged) {
        if (this.config.printFieldsOnNewLines) {
            return `{\n  ${allObjectsMerged.join(',\n  ')}\n}`;
        }
        return `{ ${allObjectsMerged.join(', ')} }`;
    }
    buildSelectionSetFromStrings(pieces) {
        if (pieces.length === 0) {
            return null;
        }
        if (pieces.length === 1) {
            return pieces[0];
        }
        return `(\n  ${pieces.join(`\n  & `)}\n)`;
    }
    transformPrimitiveFields(_schemaType, _fields, _unsetTypes) {
        throw new Error(`Please override "transformPrimitiveFields" as part of your BaseSelectionSetProcessor implementation!`);
    }
    transformAliasesPrimitiveFields(_schemaType, _fields, _unsetTypes) {
        throw new Error(`Please override "transformAliasesPrimitiveFields" as part of your BaseSelectionSetProcessor implementation!`);
    }
    transformLinkFields(_fields, _unsetTypes) {
        throw new Error(`Please override "transformLinkFields" as part of your BaseSelectionSetProcessor implementation!`);
    }
    transformTypenameField(_type, _name) {
        throw new Error(`Please override "transformTypenameField" as part of your BaseSelectionSetProcessor implementation!`);
    }
}
