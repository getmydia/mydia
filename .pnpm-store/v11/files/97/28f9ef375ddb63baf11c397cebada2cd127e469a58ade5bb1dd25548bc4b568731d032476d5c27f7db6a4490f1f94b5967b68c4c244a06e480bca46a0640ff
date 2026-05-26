"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.isLegacyConfig = isLegacyConfig;
exports.createCosmiConfig = createCosmiConfig;
exports.createCosmiConfigSync = createCosmiConfigSync;
const cosmiconfig_1 = require("cosmiconfig");
const string_env_interpolation_1 = require("string-env-interpolation");
const jiti_1 = require("jiti");
const legacySearchPlaces = [
    '.graphqlconfig',
    '.graphqlconfig.json',
    '.graphqlconfig.yaml',
    '.graphqlconfig.yml',
];
function isLegacyConfig(filePath) {
    filePath = filePath.toLowerCase();
    return legacySearchPlaces.some((name) => filePath.endsWith(name));
}
function transformContent(content) {
    return (0, string_env_interpolation_1.env)(content);
}
function createCustomLoader(loader) {
    return (filePath, content) => loader(filePath, transformContent(content));
}
function createCosmiConfig(moduleName, legacy) {
    const options = prepareCosmiconfig(moduleName, legacy, 'async');
    return (0, cosmiconfig_1.cosmiconfig)(moduleName, options);
}
function createCosmiConfigSync(moduleName, legacy) {
    const options = prepareCosmiconfig(moduleName, legacy, 'sync');
    return (0, cosmiconfig_1.cosmiconfigSync)(moduleName, options);
}
const loadTypeScript = (filepath) => {
    const jiti = (0, jiti_1.createJiti)(__filename, { interopDefault: true });
    return jiti.import(filepath);
};
const loadTypeScriptSync = (filepath) => {
    const jiti = (0, jiti_1.createJiti)(__filename, { interopDefault: true });
    return jiti(filepath);
};
const loadToml = (...args) => {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { loadToml } = require('cosmiconfig-toml-loader');
    return createCustomLoader(loadToml)(...args);
};
const loadYaml = createCustomLoader(cosmiconfig_1.defaultLoaders['.yaml']);
function prepareCosmiconfig(moduleName, legacy, mode) {
    const searchPlaces = [
        '#.config.ts',
        '#.config.cts',
        '#.config.mts',
        '#.config.js',
        '#.config.cjs',
        '#.config.mjs',
        '#.config.json',
        '#.config.yaml',
        '#.config.yml',
        '#.config.toml',
        '.#rc',
        '.#rc.ts',
        '.#rc.cts',
        '.#rc.mts',
        '.#rc.js',
        '.#rc.cjs',
        '.#rc.mjs',
        '.#rc.json',
        '.#rc.yml',
        '.#rc.yaml',
        '.#rc.toml',
        'package.json',
    ];
    if (legacy) {
        searchPlaces.push(...legacySearchPlaces);
    }
    // We need to wrap loaders in order to access and transform file content (as string)
    // Cosmiconfig has transform option but at this point config is not a string but an object
    return {
        searchPlaces: searchPlaces.map((place) => place.replace('#', moduleName)),
        loaders: {
            '.ts': mode === 'async' ? loadTypeScript : loadTypeScriptSync,
            '.cts': mode === 'async' ? loadTypeScript : loadTypeScriptSync,
            '.mts': mode === 'async' ? loadTypeScript : loadTypeScriptSync,
            '.js': mode === 'async' ? loadTypeScript : loadTypeScriptSync,
            '.mjs': mode === 'async' ? loadTypeScript : loadTypeScriptSync,
            '.json': cosmiconfig_1.defaultLoaders['.json'],
            '.yaml': loadYaml,
            '.yml': loadYaml,
            '.toml': loadToml,
            noExt: loadYaml,
        },
    };
}
