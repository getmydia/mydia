"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.ApolloFederation = exports.federationSpec = void 0;
exports.addFederationReferencesToSchema = addFederationReferencesToSchema;
exports.removeFederation = removeFederation;
const graphql_1 = require("graphql");
const utils_1 = require("@graphql-tools/utils");
const index_js_1 = require("./index.js");
const utils_js_1 = require("./utils.js");
/**
 * Federation Spec
 */
exports.federationSpec = (0, graphql_1.parse)(/* GraphQL */ `
  scalar _FieldSet

  directive @external on FIELD_DEFINITION
  directive @requires(fields: _FieldSet!) on FIELD_DEFINITION
  directive @provides(fields: _FieldSet!) on FIELD_DEFINITION
  directive @key(fields: _FieldSet!) on OBJECT | INTERFACE
`);
/**
 * Adds `__resolveReference` in each ObjectType and InterfaceType involved in Federation.
 * We do this to utilise the existing FieldDefinition logic of the plugin, which includes many logic:
 * - mapper
 * - return type
 * @param schema
 */
function addFederationReferencesToSchema(schema) {
    const setFederationMeta = ({ meta, typeName, update, }) => {
        meta[typeName] = {
            ...(meta[typeName] ||
                {
                    hasResolveReference: false,
                    resolvableKeyDirectives: [],
                    referenceSelectionSets: [],
                    referenceSelectionSetsString: '',
                }),
            ...update,
        };
    };
    const getReferenceSelectionSets = ({ resolvableKeyDirectives, fields, }) => {
        const referenceSelectionSets = [];
        // @key() @key() - "primary keys" in Federation
        // A reference may receive one primary key combination at a time, so they will be combined with `|`
        const primaryKeys = resolvableKeyDirectives.map(extractReferenceSelectionSet);
        referenceSelectionSets.push({
            directive: '@key',
            selectionSets: [...primaryKeys],
        });
        const requiresPossibleTypes = [];
        for (const fieldNode of Object.values(fields)) {
            // Look for @requires and see what the service needs and gets
            const directives = getDirectivesByName('requires', fieldNode.astNode);
            for (const directive of directives) {
                const requires = extractReferenceSelectionSet(directive);
                requiresPossibleTypes.push(requires);
            }
        }
        referenceSelectionSets.push({
            directive: '@requires',
            selectionSets: requiresPossibleTypes,
        });
        return referenceSelectionSets;
    };
    /**
     * Function to find all combinations of selection sets and push them into the `result`
     * This is used for `@requires` directive because depending on the operation selection set, different
     * combination of fields are sent from the router.
     *
     * @example
     * Input: [
     *   { a: true },
     *   { b: true },
     *   { c: true },
     *   { d: true},
     * ]
     * Output: [
     *   { a: true },
     *   { a: true, b: true },
     *   { a: true, c: true },
     *   { a: true, d: true },
     *   { a: true, b: true, c: true },
     *   { a: true, b: true, d: true },
     *   { a: true, c: true, d: true },
     *   { a: true, b: true, c: true, d: true }
     *
     *   { b: true },
     *   { b: true, c: true },
     *   { b: true, d: true },
     *   { b: true, c: true, d: true }
     *
     *   { c: true },
     *   { c: true, d: true },
     *
     *   { d: true },
     * ]
     * ```
     */
    function findAllSelectionSetCombinations(selectionSets, result) {
        if (selectionSets.length === 0) {
            return;
        }
        for (let baseIndex = 0; baseIndex < selectionSets.length; baseIndex++) {
            const base = selectionSets.slice(0, baseIndex + 1);
            const rest = selectionSets.slice(baseIndex + 1, selectionSets.length);
            const currentSelectionSet = base.reduce((acc, selectionSet) => {
                acc = { ...acc, ...selectionSet };
                return acc;
            }, {});
            if (baseIndex === 0) {
                result.push(currentSelectionSet);
            }
            for (const selectionSet of rest) {
                result.push({ ...currentSelectionSet, ...selectionSet });
            }
        }
        const next = selectionSets.slice(1, selectionSets.length);
        if (next.length > 0) {
            findAllSelectionSetCombinations(next, result);
        }
    }
    const printReferenceSelectionSets = ({ typeName, baseFederationType, referenceSelectionSets, }) => {
        const referenceSelectionSetStrings = referenceSelectionSets.reduce((acc, { directive, selectionSets: originalSelectionSets }) => {
            const result = [];
            let selectionSets = originalSelectionSets;
            if (directive === '@requires') {
                selectionSets = [];
                findAllSelectionSetCombinations(originalSelectionSets, selectionSets);
                if (selectionSets.length > 0) {
                    result.push('Record<PropertyKey, never>');
                }
            }
            for (const referenceSelectionSet of selectionSets) {
                result.push(`GraphQLRecursivePick<${baseFederationType}, ${JSON.stringify(referenceSelectionSet)}>`);
            }
            if (result.length === 0) {
                return acc;
            }
            if (result.length === 1) {
                acc.push(result.join(' | '));
                return acc;
            }
            acc.push(`( ${result.join('\n        | ')} )`);
            return acc;
        }, []);
        return `\n    ( { __typename: '${typeName}' }\n    & ${referenceSelectionSetStrings.join('\n    & ')} )`;
    };
    const federationMeta = {};
    const transformedSchema = (0, utils_1.mapSchema)(schema, {
        [utils_1.MapperKind.INTERFACE_TYPE]: type => {
            const node = (0, utils_1.astFromInterfaceType)(type, schema);
            const federationDetails = checkTypeFederationDetails(node, schema);
            if (federationDetails && federationDetails.resolvableKeyDirectives.length > 0) {
                const typeConfig = type.toConfig();
                typeConfig.fields = {
                    [resolveReferenceFieldName]: {
                        type,
                    },
                    ...typeConfig.fields,
                };
                const referenceSelectionSets = getReferenceSelectionSets({
                    resolvableKeyDirectives: federationDetails.resolvableKeyDirectives,
                    fields: typeConfig.fields,
                });
                const referenceSelectionSetsString = printReferenceSelectionSets({
                    typeName: type.name,
                    baseFederationType: `FederationTypes['${type.name}']`, // FIXME: run convertName on FederationTypes
                    referenceSelectionSets,
                });
                setFederationMeta({
                    meta: federationMeta,
                    typeName: type.name,
                    update: {
                        hasResolveReference: true,
                        resolvableKeyDirectives: federationDetails.resolvableKeyDirectives,
                        referenceSelectionSets,
                        referenceSelectionSetsString,
                    },
                });
                return new graphql_1.GraphQLInterfaceType(typeConfig);
            }
            return type;
        },
        [utils_1.MapperKind.OBJECT_TYPE]: type => {
            const node = (0, utils_1.astFromObjectType)(type, schema);
            const federationDetails = checkTypeFederationDetails(node, schema);
            if (federationDetails && federationDetails.resolvableKeyDirectives.length > 0) {
                const typeConfig = type.toConfig();
                const referenceSelectionSets = getReferenceSelectionSets({
                    resolvableKeyDirectives: federationDetails.resolvableKeyDirectives,
                    fields: typeConfig.fields,
                });
                typeConfig.fields = {
                    [resolveReferenceFieldName]: {
                        type,
                    },
                    ...typeConfig.fields,
                };
                const referenceSelectionSetsString = printReferenceSelectionSets({
                    typeName: type.name,
                    baseFederationType: `FederationTypes['${type.name}']`, // FIXME: run convertName on FederationTypes
                    referenceSelectionSets,
                });
                setFederationMeta({
                    meta: federationMeta,
                    typeName: type.name,
                    update: {
                        hasResolveReference: true,
                        resolvableKeyDirectives: federationDetails.resolvableKeyDirectives,
                        referenceSelectionSets,
                        referenceSelectionSetsString,
                    },
                });
                return new graphql_1.GraphQLObjectType(typeConfig);
            }
            return type;
        },
    });
    return {
        transformedSchema,
        federationMeta,
    };
}
/**
 * Removes Federation Spec from GraphQL Schema
 * @param schema
 * @param config
 */
function removeFederation(schema) {
    return (0, utils_1.mapSchema)(schema, {
        [utils_1.MapperKind.QUERY]: queryType => {
            const queryTypeConfig = queryType.toConfig();
            delete queryTypeConfig.fields._entities;
            delete queryTypeConfig.fields._service;
            return new graphql_1.GraphQLObjectType(queryTypeConfig);
        },
        [utils_1.MapperKind.UNION_TYPE]: unionType => {
            const unionTypeName = unionType.name;
            if (unionTypeName === '_Entity' || unionTypeName === '_Any') {
                return null;
            }
            return unionType;
        },
        [utils_1.MapperKind.OBJECT_TYPE]: objectType => {
            if (objectType.name === '_Service') {
                return null;
            }
            return objectType;
        },
    });
}
const resolveReferenceFieldName = '__resolveReference';
class ApolloFederation {
    enabled = false;
    schema;
    providesMap;
    /**
     * `fieldsToGenerate` is a meta object where the keys are object type names
     * and the values are fields that must be generated for that object.
     */
    fieldsToGenerate;
    meta = {};
    constructor({ enabled, schema, meta, }) {
        this.enabled = enabled;
        this.schema = schema;
        this.providesMap = this.createMapOfProvides();
        this.fieldsToGenerate = {};
        this.meta = meta;
    }
    /**
     * Excludes types definde by Federation
     * @param typeNames List of type names
     */
    filterTypeNames(typeNames) {
        return this.enabled ? typeNames.filter(t => t !== '_FieldSet') : typeNames;
    }
    /**
     * Excludes `__resolveReference` fields
     * @param fieldNames List of field names
     */
    filterFieldNames(fieldNames) {
        return this.enabled ? fieldNames.filter(t => t !== resolveReferenceFieldName) : fieldNames;
    }
    /**
     * Decides if directive should not be generated
     * @param name directive's name
     */
    skipDirective(name) {
        return this.enabled && ['external', 'requires', 'provides', 'key'].includes(name);
    }
    /**
     * Decides if scalar should not be generated
     * @param name directive's name
     */
    skipScalar(name) {
        return this.enabled && name === '_FieldSet';
    }
    /**
     * findFieldNodesToGenerate
     * @description Function to find field nodes to generate.
     * In a normal setup, all fields must be generated.
     * However, in a Federatin setup, a field should not be generated if:
     * - The field is marked as `@external` and there is no `@provides` path to the field
     * - The parent object is marked as `@external` and there is no `@provides` path to the field
     */
    findFieldNodesToGenerate({ node, }) {
        const nodeName = node.name.value;
        if (this.fieldsToGenerate[nodeName]) {
            return this.fieldsToGenerate[nodeName];
        }
        const fieldNodes = (node.fields || []).map(field => field.node);
        if (!this.enabled) {
            return fieldNodes;
        }
        // If the object is marked with `@external`, fields to generate are those with `@provides`
        if (this.isExternal(node)) {
            const fieldNodesWithProvides = fieldNodes.reduce((acc, fieldNode) => {
                if (this.hasProvides(node, fieldNode.name.value)) {
                    acc.push(fieldNode);
                    return acc;
                }
                return acc;
            }, []);
            this.fieldsToGenerate[nodeName] = fieldNodesWithProvides;
            return fieldNodesWithProvides;
        }
        // If the object is not marked with `@external`, fields to generate are:
        // - the fields without `@external`
        // - the `@external` fields with `@provides`
        const fieldNodesWithoutExternalOrHasProvides = fieldNodes.reduce((acc, fieldNode) => {
            if (!this.isExternal(fieldNode)) {
                acc.push(fieldNode);
                return acc;
            }
            if (this.isExternal(fieldNode) && this.hasProvides(node, fieldNode.name.value)) {
                acc.push(fieldNode);
                return acc;
            }
            return acc;
        }, []);
        this.fieldsToGenerate[nodeName] = fieldNodesWithoutExternalOrHasProvides;
        return fieldNodesWithoutExternalOrHasProvides;
    }
    isResolveReferenceField(fieldNode) {
        const name = typeof fieldNode.name === 'string' ? fieldNode.name : fieldNode.name.value;
        return this.enabled && name === resolveReferenceFieldName;
    }
    addFederationTypeGenericIfApplicable({ genericTypes, typeName, federationTypesType, }) {
        if (!this.getMeta()[typeName]) {
            return;
        }
        const typeRef = `${federationTypesType}['${typeName}']`;
        genericTypes.push(`FederationReferenceType extends ${typeRef} = ${typeRef}`);
    }
    getMeta() {
        return this.meta;
    }
    isExternal(node) {
        return getDirectivesByName('external', node).length > 0;
    }
    hasProvides(node, fieldName) {
        const fields = this.providesMap[node.name.value];
        if (fields?.length) {
            return fields.includes(fieldName);
        }
        return false;
    }
    createMapOfProvides() {
        const providesMap = {};
        for (const typename of Object.keys(this.schema.getTypeMap())) {
            const objectType = this.schema.getType(typename);
            if ((0, graphql_1.isObjectType)(objectType)) {
                for (const field of Object.values(objectType.getFields())) {
                    const provides = getDirectivesByName('provides', field.astNode)
                        .map(extractReferenceSelectionSet)
                        .reduce((prev, curr) => [...prev, ...Object.keys(curr)], []); // FIXME: this is not taking into account nested selection sets e.g. `company { taxCode }`
                    const ofType = (0, utils_js_1.getBaseType)(field.type);
                    providesMap[ofType.name] ||= [];
                    providesMap[ofType.name].push(...provides);
                }
            }
        }
        return providesMap;
    }
}
exports.ApolloFederation = ApolloFederation;
/**
 * Checks if Object Type is involved in Federation. Based on `@key` directive
 * @param node Type
 */
function checkTypeFederationDetails(node, schema) {
    const name = node.name.value;
    const directives = node.directives;
    const rootTypeNames = (0, utils_1.getRootTypeNames)(schema);
    const isNotRoot = !rootTypeNames.has(name);
    const isNotIntrospection = !name.startsWith('__');
    const keyDirectives = directives.filter(d => d.name.value === 'key');
    const check = isNotRoot && isNotIntrospection && keyDirectives.length > 0;
    if (!check) {
        return false;
    }
    const resolvableKeyDirectives = keyDirectives.filter(d => {
        for (const arg of d.arguments) {
            if (arg.name.value === 'resolvable' &&
                arg.value.kind === 'BooleanValue' &&
                arg.value.value === false) {
                return false;
            }
        }
        return true;
    });
    return { resolvableKeyDirectives };
}
/**
 * Extracts directives from a node based on directive's name
 * @param name directive name
 * @param node ObjectType or Field
 */
function getDirectivesByName(name, node) {
    return node?.directives?.filter(d => d.name.value === name) || [];
}
function extractReferenceSelectionSet(directive) {
    const arg = directive.arguments.find(arg => arg.name.value === 'fields');
    const { value } = arg.value;
    return (0, index_js_1.oldVisit)((0, graphql_1.parse)(`{${value}}`), {
        leave: {
            SelectionSet(node) {
                return node.selections.reduce((accum, field) => {
                    accum[field.name] = field.selection;
                    return accum;
                }, {});
            },
            Field(node) {
                return {
                    name: node.name.value,
                    selection: node.selectionSet || true,
                };
            },
            Document(node) {
                return node.definitions.find((def) => def.kind === 'OperationDefinition' && def.operation === 'query').selectionSet;
            },
        },
    });
}
