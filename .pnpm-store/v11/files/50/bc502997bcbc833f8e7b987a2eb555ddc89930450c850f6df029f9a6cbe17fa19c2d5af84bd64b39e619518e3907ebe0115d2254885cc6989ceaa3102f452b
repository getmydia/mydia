import { Kind } from 'graphql';
export class FederatedLinkImport {
    name;
    as;
    constructor(name, as) {
        this.name = name;
        this.as = as;
    }
    toString() {
        return this.as ? `{ name: "${this.name}", as: "${this.as}" }` : `"${this.name}"`;
    }
    static fromTypedefs(node) {
        if (node.kind === Kind.LIST) {
            const imports = node.values.map(v => {
                if (v.kind === Kind.STRING) {
                    return new FederatedLinkImport(v.value, null);
                }
                if (v.kind === Kind.OBJECT) {
                    let name = '';
                    let as = null;
                    v.fields.forEach(f => {
                        if (f.name.value === 'name') {
                            if (f.value.kind !== Kind.STRING) {
                                throw new Error(`Expected string value for @link "name" field but got "${f.value.kind}"`);
                            }
                            name = f.value.value;
                        }
                        else if (f.name.value === 'as') {
                            if (f.value.kind !== Kind.STRING) {
                                throw new Error(`Expected string value for @link "as" field but got "${f.value.kind}"`);
                            }
                            as = f.value.value;
                        }
                    });
                    return new FederatedLinkImport(name, as);
                }
                throw new Error(`Unexpected value kind "${v.kind}" in @link import declaration`);
            });
            return imports;
        }
        throw new Error(`Expected a list of @link imports but got "${node.kind}"`);
    }
}
