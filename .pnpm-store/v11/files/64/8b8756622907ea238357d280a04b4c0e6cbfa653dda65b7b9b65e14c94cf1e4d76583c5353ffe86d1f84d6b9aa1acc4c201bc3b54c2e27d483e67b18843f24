"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getDocumentTransform = getDocumentTransform;
exports.getDocumentTransformByName = getDocumentTransformByName;
const path_1 = require("path");
async function getDocumentTransform(documentTransform, loader, defaultName) {
    if (typeof documentTransform === 'string') {
        const transformObject = await getDocumentTransformByName(documentTransform, loader);
        return { name: documentTransform, transformObject };
    }
    if (isTransformObject(documentTransform)) {
        return { name: defaultName, transformObject: documentTransform };
    }
    if (isTransformFileConfig(documentTransform)) {
        const name = Object.keys(documentTransform)[0];
        const transformObject = await getDocumentTransformByName(name, loader);
        return {
            name,
            transformObject,
            config: Object.values(documentTransform)[0],
        };
    }
    throw new Error(`
        An unknown format document transform: '${defaultName}'.
    `);
}
function isTransformObject(config) {
    return typeof config === 'object' && config.transform && typeof config.transform === 'function';
}
function isTransformFileConfig(config) {
    const keys = Object.keys(config);
    return keys.length === 1 && typeof keys[0] === 'string';
}
async function getDocumentTransformByName(name, loader) {
    const possibleNames = [
        `@graphql-codegen/${name}`,
        `@graphql-codegen/${name}-document-transform`,
        name,
        (0, path_1.resolve)(process.cwd(), name),
    ];
    const possibleModules = possibleNames.concat((0, path_1.resolve)(process.cwd(), name));
    for (const moduleName of possibleModules) {
        try {
            return await loader(moduleName);
        }
        catch (err) {
            if (err.code !== 'MODULE_NOT_FOUND' && err.code !== 'ERR_MODULE_NOT_FOUND') {
                throw new Error(`
              Unable to load document transform matching '${name}'.
              Reason:
                ${err.message}
            `);
            }
        }
    }
    const possibleNamesMsg = possibleNames
        .map(name => `
        - ${name}
    `.trimEnd())
        .join('');
    throw new Error(`
        Unable to find document transform matching '${name}'
        Install one of the following packages:

        ${possibleNamesMsg}
      `);
}
