import autoBind from 'auto-bind';
import { TsVisitor } from './visitor.js';
export class TsIntrospectionVisitor extends TsVisitor {
    typesToInclude = [];
    constructor(schema, pluginConfig = {}, typesToInclude) {
        super(schema, pluginConfig);
        this.typesToInclude = typesToInclude;
        autoBind(this);
    }
    DirectiveDefinition() {
        return null;
    }
    ObjectTypeDefinition(node, key, parent) {
        const name = node.name.value;
        if (this.typesToInclude.some(type => type.name === name)) {
            return super.ObjectTypeDefinition(node, key, parent);
        }
        return null;
    }
    EnumTypeDefinition(node) {
        const name = node.name.value;
        if (this.typesToInclude.some(type => type.name === name)) {
            return super.EnumTypeDefinition(node);
        }
        return null;
    }
}
