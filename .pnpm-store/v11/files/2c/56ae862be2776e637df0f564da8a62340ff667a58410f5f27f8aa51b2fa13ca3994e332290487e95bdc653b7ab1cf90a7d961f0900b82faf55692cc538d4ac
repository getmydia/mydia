"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.FederatedLink = void 0;
const graphql_1 = require("graphql");
const link_import_js_1 = require("./link-import.js");
const link_url_js_1 = require("./link-url.js");
/**
 * Supports federation 1
 */
function linkFromCoreArgs(args) {
    const feature = args.find(({ name, value }) => name.value === 'feature' && value.kind === graphql_1.Kind.STRING);
    if (feature) {
        const url = link_url_js_1.FederatedLinkUrl.fromUrl(feature.value.value);
        return new FederatedLink(url, null, []);
    }
}
function linkFromArgs(args) {
    let url;
    let imports = [];
    let as = null;
    for (const arg of args) {
        switch (arg.name.value) {
            case 'url': {
                if (arg.value.kind === graphql_1.Kind.STRING) {
                    url = link_url_js_1.FederatedLinkUrl.fromUrl(arg.value.value);
                }
                else {
                    console.warn(`Unexpected kind, ${arg.value.kind}, for argument "url" in @link.`);
                }
                break;
            }
            case 'import': {
                imports = link_import_js_1.FederatedLinkImport.fromTypedefs(arg.value);
                break;
            }
            case 'as': {
                if (arg.value.kind === graphql_1.Kind.STRING) {
                    as = arg.value.value ?? null;
                }
                else {
                    console.warn(`Unexpected kind, ${arg.value.kind}, for argument "as" in @link.`);
                }
                break;
            }
            default: {
                // ignore. Federation should validate links.
            }
        }
    }
    if (url !== undefined) {
        return new FederatedLink(url, as, imports);
    }
}
function namespaced(namespace, name) {
    if (namespace?.length) {
        if (name.startsWith('@')) {
            return `@${namespace}__${name.substring(1)}`;
        }
        return `${namespace}__${name}`;
    }
    return name;
}
class FederatedLink {
    _url;
    _as;
    _imports;
    constructor(_url, _as, _imports) {
        this._url = _url;
        this._as = _as;
        this._imports = _imports;
    }
    /** Collects all `@link`s defined in graphql typedefs */
    static fromTypedefs(typeDefs) {
        let links = [];
        for (const definition of typeDefs.definitions) {
            if (definition.kind === graphql_1.Kind.SCHEMA_EXTENSION || definition.kind === graphql_1.Kind.SCHEMA_DEFINITION) {
                const defLinks = definition.directives?.filter(directive => directive.name.value === 'link');
                const parsedLinks = defLinks?.map(l => linkFromArgs(l.arguments ?? [])).filter(l => l !== undefined) ?? [];
                links = links.concat(parsedLinks);
                // Federation 1 support... Federation 1 uses "@core" instead of "@link", but behavior is similar enough that
                //  it can be translated.
                const defCores = definition.directives?.filter(({ name }) => name.value === 'core');
                const coreLinks = defCores
                    ?.map(c => linkFromCoreArgs(c.arguments ?? []))
                    .filter(l => l !== undefined);
                if (coreLinks) {
                    links = links.concat(...coreLinks);
                }
            }
        }
        return links;
    }
    /**
     * By default, `@link` will assign a prefix based on the name extracted from the URL.
     * If no name is present, a prefix will not be assigned.
     * See: https://specs.apollo.dev/link/v1.0/#@link.as
     */
    get namespace() {
        return this._as ?? this._url.name;
    }
    toString() {
        return `@link(url: "${this._url}"${this._as ? `, as: "${this._as}"` : ''}${this._imports.length ? `, import: [${this._imports.join(', ')}]` : ''})`;
    }
    get defaultImport() {
        return this.namespace && `@${this.namespace}`;
    }
    /** The Link's identity. This is the unique identifier of a `@link`. */
    get identity() {
        return this._url.identity;
    }
    supports(...args) {
        /** @ts-expect-error: ignore tuple error. These are tuples and can be spread. tsc is wrong. */
        return this._url.supports(...args);
    }
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
    resolveImportName(elementName) {
        if (this._url.name && elementName === `@${this._url.name}`) {
            // @note: default is a directive... So remove the `@`
            return this.defaultImport.substring(1);
        }
        const imported = this._imports.find(i => i.name === elementName);
        const resolvedName = imported?.as ?? imported?.name ?? namespaced(this.namespace, elementName);
        // Strip the `@` prefix for directives because in all implementations of mapping or visiting a schema,
        // directive names are not prefixed with `@`. The `@` is only for SDL.
        return resolvedName.startsWith('@') ? resolvedName.substring(1) : resolvedName;
    }
    get imports() {
        return this._imports;
    }
}
exports.FederatedLink = FederatedLink;
