"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getCustomLoaderByPath = getCustomLoaderByPath;
exports.useCustomLoader = useCustomLoader;
exports.useCustomLoaderSync = useCustomLoaderSync;
const module_1 = require("module");
const path_1 = require("path");
function getCustomLoaderByPath(path, cwd) {
    try {
        const requireFn = (0, module_1.createRequire)((0, path_1.join)(cwd, 'noop.js'));
        const requiredModule = requireFn(path);
        if (requiredModule) {
            if (requiredModule.default && typeof requiredModule.default === 'function') {
                return requiredModule.default;
            }
            if (typeof requiredModule === 'function') {
                return requiredModule;
            }
        }
    }
    catch (e) { }
    return null;
}
async function useCustomLoader(loaderPointer, cwd) {
    let loader;
    if (typeof loaderPointer === 'string') {
        loader = await getCustomLoaderByPath(loaderPointer, cwd);
    }
    else if (typeof loaderPointer === 'function') {
        loader = loaderPointer;
    }
    if (typeof loader !== 'function') {
        throw new Error(`Failed to load custom loader: ${loaderPointer}`);
    }
    return loader;
}
function useCustomLoaderSync(loaderPointer, cwd) {
    let loader;
    if (typeof loaderPointer === 'string') {
        loader = getCustomLoaderByPath(loaderPointer, cwd);
    }
    else if (typeof loaderPointer === 'function') {
        loader = loaderPointer;
    }
    if (typeof loader !== 'function') {
        throw new Error(`Failed to load custom loader: ${loaderPointer}`);
    }
    return loader;
}
