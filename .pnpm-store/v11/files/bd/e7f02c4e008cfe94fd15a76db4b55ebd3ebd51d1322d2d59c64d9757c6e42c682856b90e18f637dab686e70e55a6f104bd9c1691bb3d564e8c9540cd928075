import { extname } from 'path';
import { concatAST, Kind } from 'graphql';
import { oldVisit } from '@graphql-codegen/plugin-helpers';
import { UrqlVisitor } from './visitor.js';
export const plugin = (schema, documents, config) => {
    const allAst = concatAST(documents.map(v => v.document));
    const allFragments = [
        ...allAst.definitions.filter(d => d.kind === Kind.FRAGMENT_DEFINITION).map(fragmentDef => ({
            node: fragmentDef,
            name: fragmentDef.name.value,
            onType: fragmentDef.typeCondition.name.value,
            isExternal: false,
        })),
        ...(config.externalFragments || []),
    ];
    const visitor = new UrqlVisitor(schema, allFragments, config);
    const visitorResult = oldVisit(allAst, { leave: visitor });
    return {
        prepend: visitor.getImports(),
        content: [
            visitor.fragments,
            ...visitorResult.definitions.filter(t => typeof t === 'string'),
        ].join('\n'),
    };
};
export const validate = async (schema, documents, config, outputFile) => {
    if (config.withComponent === true) {
        if (extname(outputFile) !== '.tsx') {
            throw new Error(`Plugin "typescript-urql" requires extension to be ".tsx" when withComponent: true is set!`);
        }
    }
    else if (extname(outputFile) !== '.ts' && extname(outputFile) !== '.tsx') {
        throw new Error(`Plugin "typescript-urql" requires extension to be ".ts" or ".tsx"!`);
    }
};
export { UrqlVisitor };
