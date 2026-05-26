"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.isObjectMap = isObjectMap;
exports.prioritize = prioritize;
exports.pickFlag = pickFlag;
exports.shouldValidateDuplicateDocuments = shouldValidateDuplicateDocuments;
exports.shouldValidateDocumentsAgainstSchema = shouldValidateDocumentsAgainstSchema;
exports.getSkipDocumentsValidationOption = getSkipDocumentsValidationOption;
exports.hasFederationSpec = hasFederationSpec;
exports.extractHashFromSchema = extractHashFromSchema;
const graphql_1 = require("graphql");
const utils_1 = require("@graphql-tools/utils");
function isObjectMap(obj) {
    return obj && typeof obj === 'object' && !Array.isArray(obj);
}
function prioritize(...values) {
    const picked = values.find(val => typeof val === 'boolean');
    if (typeof picked !== 'boolean') {
        return values[values.length - 1];
    }
    return picked;
}
function pickFlag(flag, config) {
    return isObjectMap(config) ? config[flag] : undefined;
}
function shouldValidateDuplicateDocuments(skipDocumentsValidationOption) {
    // If the value is true, skip all
    if (skipDocumentsValidationOption === true) {
        return false;
    }
    // If the value is object with the specific flag, only skip this one
    if (typeof skipDocumentsValidationOption === 'object' &&
        skipDocumentsValidationOption.skipDuplicateValidation) {
        return false;
    }
    // If the value is falsy or the specific flag is not set, validate
    return true;
}
function shouldValidateDocumentsAgainstSchema(skipDocumentsValidationOption) {
    // If the value is true, skip all
    if (skipDocumentsValidationOption === true) {
        return false;
    }
    // If the value is object with the specific flag, only skip this one
    if (typeof skipDocumentsValidationOption === 'object' &&
        skipDocumentsValidationOption.skipValidationAgainstSchema) {
        return false;
    }
    // If the value is falsy or the specific flag is not set, validate
    return true;
}
function getSkipDocumentsValidationOption(options) {
    // If the value is set on the root level
    if (options.skipDocumentsValidation) {
        return options.skipDocumentsValidation;
    }
    // If the value is set under `config` property
    const flagFromConfig = pickFlag('skipDocumentsValidation', options.config);
    if (flagFromConfig) {
        return flagFromConfig;
    }
    return false;
}
const federationDirectives = ['key', 'requires', 'provides', 'external'];
function hasFederationSpec(schemaOrAST) {
    if ((0, graphql_1.isSchema)(schemaOrAST)) {
        return federationDirectives.some(directive => schemaOrAST.getDirective(directive));
    }
    if ((0, utils_1.isDocumentNode)(schemaOrAST)) {
        return schemaOrAST.definitions.some(def => def.kind === graphql_1.Kind.DIRECTIVE_DEFINITION && federationDirectives.includes(def.name.value));
    }
    return false;
}
function extractHashFromSchema(schema) {
    schema.extensions ||= {};
    return schema.extensions['hash'] ?? null;
}
