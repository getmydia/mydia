"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.isMultipleProjectConfig = isMultipleProjectConfig;
exports.isSingleProjectConfig = isSingleProjectConfig;
exports.isLegacyProjectConfig = isLegacyProjectConfig;
exports.useMiddleware = useMiddleware;
function isMultipleProjectConfig(config) {
    return typeof config.projects === 'object';
}
function isSingleProjectConfig(config) {
    return config.schema !== undefined;
}
function isLegacyProjectConfig(config) {
    return (config.schemaPath !== undefined ||
        config.includes !== undefined ||
        config.excludes !== undefined);
}
function useMiddleware(fns) {
    return (input) => {
        if (fns.length) {
            return fns.reduce((obj, cb) => cb(obj), input);
        }
        return input;
    };
}
