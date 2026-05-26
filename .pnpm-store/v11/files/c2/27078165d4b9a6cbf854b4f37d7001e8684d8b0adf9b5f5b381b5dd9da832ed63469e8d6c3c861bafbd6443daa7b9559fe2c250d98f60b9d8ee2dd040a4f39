import { DocumentNode } from 'graphql';
import { FederatedLinkImport } from './link-import.cjs';
import { FederatedLinkUrl } from './link-url.cjs';
export declare class FederatedLink {
    private readonly _url;
    private readonly _as;
    private readonly _imports;
    constructor(_url: FederatedLinkUrl, _as: string | null, _imports: FederatedLinkImport[]);
    /** Collects all `@link`s defined in graphql typedefs */
    static fromTypedefs(typeDefs: DocumentNode): FederatedLink[];
    /**
     * By default, `@link` will assign a prefix based on the name extracted from the URL.
     * If no name is present, a prefix will not be assigned.
     * See: https://specs.apollo.dev/link/v1.0/#@link.as
     */
    private get namespace();
    toString(): string;
    private get defaultImport();
    /** The Link's identity. This is the unique identifier of a `@link`. */
    get identity(): string;
    supports(version: string): boolean;
    supports(major: number, minor: number): boolean;
    supports(version: FederatedLinkUrl): boolean;
    supports(version: null): boolean;
    /**
     * Given the name of an element in a linked schema, this returns the name of that element
     * as it has been imported. This accounts for aliasing and namespacing unreferenced imports.
     * This can be used within implementations to reference the translated names of elements.
     *
     * The directive `@` prefix is removed from the returned name. This is to make it easier to match node names when visiting a schema definition.
     * When visiting nodes, a directive's name doesn't include the `@`.
     * However, the `@` is necessary for the input parameter in order to know how to correctly resolve the name.
     * Otherwise, setting the import argument as: import: ["foo"] would incorrectly return `foo` for `@foo`, when it should be `{namespace}__foo`.
     *
     * @name string The element name in the linked schema. If this is the name of the link (e.g. "example" when linking "https://foo.graphql-hive.com/example"), then this returns the default link import.
     * @returns The name of the element as it has been imported.
     */
    resolveImportName(elementName: string): string;
    get imports(): readonly FederatedLinkImport[];
}
