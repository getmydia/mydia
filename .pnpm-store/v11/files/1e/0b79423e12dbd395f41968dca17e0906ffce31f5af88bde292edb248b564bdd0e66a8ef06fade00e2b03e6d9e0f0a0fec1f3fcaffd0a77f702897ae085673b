import { DirectiveNode, FieldDefinitionNode, GraphQLSchema, InterfaceTypeDefinitionNode, ObjectTypeDefinitionNode } from 'graphql';
/**
 * Federation Spec
 */
export declare const federationSpec: import("graphql").DocumentNode;
type ReferenceSelectionSet = Record<string, boolean>;
interface TypeMeta {
    hasResolveReference: boolean;
    resolvableKeyDirectives: readonly DirectiveNode[];
    /**
     * referenceSelectionSets
     * @description Each element can be `ReferenceSelectionSet[]`.
     * Elements at the root level are combined with `&` and nested elements are combined with `|`.
     *
     * @example:
     * - [[A, B], [C], [D]]      -> (A | B) & C & D
     * - [[A, B], [C, D], [E]] -> (A | B) & (C | D) & E
     */
    referenceSelectionSets: {
        directive: '@key' | '@requires';
        selectionSets: ReferenceSelectionSet[];
    }[];
    referenceSelectionSetsString: string;
}
export type FederationMeta = {
    [typeName: string]: TypeMeta;
};
/**
 * Adds `__resolveReference` in each ObjectType and InterfaceType involved in Federation.
 * We do this to utilise the existing FieldDefinition logic of the plugin, which includes many logic:
 * - mapper
 * - return type
 * @param schema
 */
export declare function addFederationReferencesToSchema(schema: GraphQLSchema): {
    transformedSchema: GraphQLSchema;
    federationMeta: FederationMeta;
};
/**
 * Removes Federation Spec from GraphQL Schema
 * @param schema
 * @param config
 */
export declare function removeFederation(schema: GraphQLSchema): GraphQLSchema;
export declare class ApolloFederation {
    private enabled;
    private schema;
    private providesMap;
    /**
     * `fieldsToGenerate` is a meta object where the keys are object type names
     * and the values are fields that must be generated for that object.
     */
    private fieldsToGenerate;
    protected meta: FederationMeta;
    constructor({ enabled, schema, meta, }: {
        enabled: boolean;
        schema: GraphQLSchema;
        meta: FederationMeta;
    });
    /**
     * Excludes types definde by Federation
     * @param typeNames List of type names
     */
    filterTypeNames(typeNames: string[]): string[];
    /**
     * Excludes `__resolveReference` fields
     * @param fieldNames List of field names
     */
    filterFieldNames(fieldNames: string[]): string[];
    /**
     * Decides if directive should not be generated
     * @param name directive's name
     */
    skipDirective(name: string): boolean;
    /**
     * Decides if scalar should not be generated
     * @param name directive's name
     */
    skipScalar(name: string): boolean;
    /**
     * findFieldNodesToGenerate
     * @description Function to find field nodes to generate.
     * In a normal setup, all fields must be generated.
     * However, in a Federatin setup, a field should not be generated if:
     * - The field is marked as `@external` and there is no `@provides` path to the field
     * - The parent object is marked as `@external` and there is no `@provides` path to the field
     */
    findFieldNodesToGenerate({ node, }: {
        node: ObjectTypeDefinitionNode | InterfaceTypeDefinitionNode;
    }): readonly FieldDefinitionNode[];
    isResolveReferenceField(fieldNode: FieldDefinitionNode): boolean;
    addFederationTypeGenericIfApplicable({ genericTypes, typeName, federationTypesType, }: {
        genericTypes: string[];
        typeName: string;
        federationTypesType: string;
    }): void;
    getMeta(): FederationMeta;
    private isExternal;
    private hasProvides;
    private createMapOfProvides;
}
export {};
