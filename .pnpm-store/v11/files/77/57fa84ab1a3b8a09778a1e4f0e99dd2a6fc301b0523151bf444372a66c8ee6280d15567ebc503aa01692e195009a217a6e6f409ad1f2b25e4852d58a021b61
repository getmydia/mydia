"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.TypeScriptSelectionSetProcessor = void 0;
const visitor_plugin_common_1 = require("@graphql-codegen/visitor-plugin-common");
class TypeScriptSelectionSetProcessor extends visitor_plugin_common_1.BaseSelectionSetProcessor {
    transformPrimitiveFields(schemaType, fields, unsetTypes) {
        if (fields.length === 0) {
            return [];
        }
        const parentName = (this.config.namespacedImportName ? `${this.config.namespacedImportName}.` : '') +
            this.config.convertName(schemaType.name, {
                useTypesPrefix: true,
            });
        if (unsetTypes) {
            const escapedFieldNames = fields.map(field => `'${field.fieldName}'`);
            return [formattedUnionTransform('MakeEmpty', parentName, escapedFieldNames)];
        }
        let hasConditionals = false;
        const escapedConditionalsList = [];
        const escapedFieldNames = fields.map(field => {
            if (field.isConditional) {
                hasConditionals = true;
                escapedConditionalsList.push(`'${field.fieldName}'`);
            }
            return `'${field.fieldName}'`;
        });
        let resString = formattedUnionTransform('Pick', parentName, escapedFieldNames);
        if (hasConditionals) {
            resString = `${this.config.namespacedImportName ? `${this.config.namespacedImportName}.` : ''}${formattedUnionTransform('MakeOptional', resString, escapedConditionalsList)}`;
        }
        return [resString];
    }
    transformTypenameField(type, name) {
        return [`{ ${name}: ${type} }`];
    }
    transformAliasesPrimitiveFields(schemaType, fields) {
        if (fields.length === 0) {
            return [];
        }
        const parentName = (this.config.namespacedImportName ? `${this.config.namespacedImportName}.` : '') +
            this.config.convertName(schemaType.name, {
                useTypesPrefix: true,
            });
        const selections = fields.map(aliasedField => {
            const value = aliasedField.fieldName === '__typename'
                ? `'${schemaType.name}'`
                : `${parentName}['${aliasedField.fieldName}']`;
            return `${aliasedField.alias}: ${value}`;
        });
        return [formatSelections(selections)];
    }
    transformLinkFields(fields) {
        if (fields.length === 0) {
            return [];
        }
        const selections = fields.map(field => `${field.alias || field.name}: ${field.selectionSet}`);
        return [formatSelections(selections)];
    }
}
exports.TypeScriptSelectionSetProcessor = TypeScriptSelectionSetProcessor;
/** Equivalent to `${transformName}<${target}, ${unionElements.join(' | ')}>`, but with line feeds if necessary */
function formattedUnionTransform(transformName, target, unionElements) {
    if (unionElements.length > 3) {
        return `${transformName}<\n    ${target},\n    | ${unionElements.join('\n    | ')}\n  >`;
    }
    return `${transformName}<${target}, ${unionElements.join(' | ')}>`;
}
/** Equivalent to `{ ${selections.join(', ')} }`, but with line feeds if necessary */
function formatSelections(selections) {
    if (selections.length > 1) {
        return `{\n    ${selections.map(s => s.replace(/\n/g, '\n  ')).join(',\n    ')},\n  }`;
    }
    return `{ ${selections.join(', ')} }`;
}
