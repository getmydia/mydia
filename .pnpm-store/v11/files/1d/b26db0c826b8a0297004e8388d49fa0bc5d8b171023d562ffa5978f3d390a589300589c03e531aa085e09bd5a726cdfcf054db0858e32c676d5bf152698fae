"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.gqlPluckFromCodeStringSync = exports.gqlPluckFromCodeString = void 0;
exports.parseCode = parseCode;
const tslib_1 = require("tslib");
/* eslint-disable @typescript-eslint/no-require-imports */
const graphql_1 = require("graphql");
const parser_1 = require("@babel/parser");
const traverse_1 = tslib_1.__importDefault(require("@babel/traverse"));
const config_js_1 = tslib_1.__importDefault(require("./config.js"));
const extname_js_1 = require("./libs/extname.js");
const utils_js_1 = require("./utils.js");
const visitor_js_1 = tslib_1.__importDefault(require("./visitor.js"));
function getDefault(module) {
    return module.default || module;
}
const traverse = getDefault(traverse_1.default);
const supportedExtensions = [
    '.js',
    '.mjs',
    '.cjs',
    '.jsx',
    '.ts',
    '.mts',
    '.cts',
    '.tsx',
    '.flow',
    '.flow.js',
    '.flow.jsx',
    '.vue',
    '.svelte',
    '.astro',
    '.gts',
    '.gjs',
];
// tslint:disable-next-line: no-implicit-dependencies
function parseWithVue(vueTemplateCompiler, typescriptPackage, fileData, filePath) {
    // Calls to registerTS are idempotent, so it's safe to call it repeatedly like
    // we are here.
    //
    // See https://github.com/ardatan/graphql-tools/pull/7271 for more details.
    //
    // @ts-expect-error - We know TypeScript version matches here
    vueTemplateCompiler.registerTS(() => typescriptPackage);
    const { descriptor } = vueTemplateCompiler.parse(fileData, { filename: filePath });
    return descriptor.script || descriptor.scriptSetup
        ? vueTemplateCompiler.compileScript(descriptor, { id: Date.now().toString() }).content
        : '';
}
function customBlockFromVue(
// tslint:disable-next-line: no-implicit-dependencies
vueTemplateCompiler, fileData, filePath, blockType) {
    const { descriptor } = vueTemplateCompiler.parse(fileData, { filename: filePath });
    const block = descriptor.customBlocks.find(b => b.type === blockType);
    if (block === undefined) {
        return;
    }
    return new graphql_1.Source(block.content.trim(), filePath, block.loc.start);
}
// tslint:disable-next-line: no-implicit-dependencies
function parseWithSvelte(svelte2tsx, fileData) {
    const fileInTsx = svelte2tsx.svelte2tsx(fileData);
    return fileInTsx.code;
}
// tslint:disable-next-line: no-implicit-dependencies
async function parseWithAstro(astroCompiler, fileData) {
    const fileInTsx = await astroCompiler.transform(fileData);
    return fileInTsx.code;
}
function parseWithAstroSync(
// tslint:disable-next-line: no-implicit-dependencies
astroCompiler, fileData) {
    const fileInTsx = astroCompiler.transform(fileData, undefined);
    return fileInTsx.code;
}
function transformGlimmerFile(glimmerSyntax, fileData) {
    const processor = new glimmerSyntax.Preprocessor();
    // backwards compatibility with older versions of content-tag
    const result = processor.process(fileData);
    if (typeof result === 'string') {
        return result;
    }
    return result.code;
}
/**
 * Asynchronously plucks GraphQL template literals from a single file.
 *
 * Supported file extensions include: `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`, `.cts`, `.tsx`, `.flow`, `.flow.js`, `.flow.jsx`, `.vue`, `.svelte`, `.astro`
 *
 * @param filePath Path to the file containing the code. Required to detect the file type
 * @param code The contents of the file being parsed.
 * @param options Additional options for determining how a file is parsed.
 */
const gqlPluckFromCodeString = async (filePath, code, options = {}) => {
    validate({ code, options });
    const fileExt = extractExtension(filePath);
    let blockSource;
    if (fileExt === '.vue') {
        if (options.gqlVueBlock) {
            blockSource = await pluckVueFileCustomBlock(code, filePath, options.gqlVueBlock);
        }
        code = await pluckVueFileScript(code, filePath);
    }
    else if (fileExt === '.svelte') {
        code = await pluckSvelteFileScript(code);
    }
    else if (fileExt === '.astro') {
        code = await pluckAstroFileScript(code);
    }
    else if (fileExt === '.gts' || fileExt === '.gjs') {
        code = await pluckGlimmerFileScript(code);
    }
    const sources = parseCode({ code, filePath, options }).map(t => new graphql_1.Source(t.content, filePath, t.loc.start));
    if (blockSource) {
        sources.push(blockSource);
    }
    return sources;
};
exports.gqlPluckFromCodeString = gqlPluckFromCodeString;
/**
 * Synchronously plucks GraphQL template literals from a single file
 *
 * Supported file extensions include: `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mjs`, `.cjs`, `.tsx`, `.flow`, `.flow.js`, `.flow.jsx`, `.vue`, `.svelte`, `.astro`, `.gts`, `.gjs`
 *
 * @param filePath Path to the file containing the code. Required to detect the file type
 * @param code The contents of the file being parsed.
 * @param options Additional options for determining how a file is parsed.
 */
const gqlPluckFromCodeStringSync = (filePath, code, options = {}) => {
    validate({ code, options });
    const fileExt = extractExtension(filePath);
    let blockSource;
    if (fileExt === '.vue') {
        if (options.gqlVueBlock) {
            blockSource = pluckVueFileCustomBlockSync(code, filePath, options.gqlVueBlock);
        }
        code = pluckVueFileScriptSync(code, filePath);
    }
    else if (fileExt === '.svelte') {
        code = pluckSvelteFileScriptSync(code);
    }
    else if (fileExt === '.astro') {
        code = pluckAstroFileScriptSync(code);
    }
    else if (fileExt === '.gts' || fileExt === '.gjs') {
        code = pluckGlimmerFileScriptSync(code);
    }
    const sources = parseCode({ code, filePath, options }).map(t => new graphql_1.Source(t.content, filePath, t.loc.start));
    if (blockSource) {
        sources.push(blockSource);
    }
    return sources;
};
exports.gqlPluckFromCodeStringSync = gqlPluckFromCodeStringSync;
function parseCode({ code, filePath, options, }) {
    const out = { returnValue: null };
    const ast = (0, parser_1.parse)(code, (0, config_js_1.default)(filePath, code, options));
    const visitor = (0, visitor_js_1.default)(code, out, options);
    traverse(ast, visitor);
    return out.returnValue || [];
}
function validate({ code, options }) {
    if (typeof code !== 'string') {
        throw TypeError('Provided code must be a string');
    }
    if (!(options instanceof Object)) {
        throw TypeError(`Options arg must be an object`);
    }
}
function extractExtension(filePath) {
    const fileExt = (0, extname_js_1.getExtNameFromFilePath)(filePath);
    if (fileExt) {
        if (!supportedExtensions.includes(fileExt)) {
            throw TypeError(`Provided file type must be one of ${supportedExtensions.join(', ')} `);
        }
    }
    return fileExt;
}
const MissingVueTemplateCompilerError = new Error((0, utils_js_1.freeText)(`
    GraphQL template literals cannot be plucked from a Vue template code without having the "@vue/compiler-sfc" package installed.
    Please install it and try again.

    Via NPM:

        $ npm install @vue/compiler-sfc

    Via Yarn:

        $ yarn add @vue/compiler-sfc
  `));
const MissingSvelteTemplateCompilerError = new Error((0, utils_js_1.freeText)(`
    GraphQL template literals cannot be plucked from a Svelte template code without having the "svelte2tsx" & "svelte" package installed.
    Please install it and try again.

    Via NPM:

        $ npm install svelte2tsx svelte

    Via Yarn:

        $ yarn add svelte2tsx svelte
  `));
const MissingAstroCompilerError = new Error((0, utils_js_1.freeText)(`
    GraphQL template literals cannot be plucked from a Astro template code without having the "@astrojs/compiler" package installed.
    Please install it and try again.

    Via NPM:

        $ npm install @astrojs/compiler

    Via Yarn:

        $ yarn add @astrojs/compiler
  `));
const MissingGlimmerCompilerError = new Error((0, utils_js_1.freeText)(`
        GraphQL template literals cannot be plucked from a Glimmer template code without having the "content-tag" package installed.
        Please install it and try again.

        Via NPM:

            $ npm install content-tag

        Via Yarn:

            $ yarn add content-tag
      `));
const MissingTypeScriptPackageError = new Error((0, utils_js_1.freeText)(`
        GraphQL template literals cannot be plucked from a Vue template code without having the "typescript" package installed.
        Please install it and try again.

        Via NPM:

            $ npm install typescript

        Via Yarn:

            $ yarn add typescript
      `));
async function loadVueCompilerAsync() {
    try {
        // eslint-disable-next-line import/no-extraneous-dependencies
        return await Promise.resolve().then(() => tslib_1.__importStar(require('@vue/compiler-sfc')));
    }
    catch {
        throw MissingVueTemplateCompilerError;
    }
}
async function loadTypeScriptPackageAsync() {
    try {
        // eslint-disable-next-line import/no-extraneous-dependencies
        return await Promise.resolve().then(() => tslib_1.__importStar(require('typescript')));
    }
    catch {
        throw MissingTypeScriptPackageError;
    }
}
function loadVueCompilerSync() {
    try {
        // eslint-disable-next-line import/no-extraneous-dependencies
        return require('@vue/compiler-sfc');
    }
    catch {
        throw MissingVueTemplateCompilerError;
    }
}
function loadTypeScriptPackageSync() {
    try {
        // eslint-disable-next-line import/no-extraneous-dependencies
        return require('typescript');
    }
    catch {
        throw MissingTypeScriptPackageError;
    }
}
async function pluckVueFileScript(fileData, filePath) {
    const [typescriptPackage, vueTemplateCompiler] = await Promise.all([
        loadTypeScriptPackageAsync(),
        loadVueCompilerAsync(),
    ]);
    return parseWithVue(vueTemplateCompiler, typescriptPackage, fileData, filePath);
}
function pluckVueFileScriptSync(fileData, filePath) {
    const vueTemplateCompiler = loadVueCompilerSync();
    const typescriptPackage = loadTypeScriptPackageSync();
    return parseWithVue(vueTemplateCompiler, typescriptPackage, fileData, filePath);
}
async function pluckVueFileCustomBlock(fileData, filePath, blockType) {
    const vueTemplateCompiler = await loadVueCompilerAsync();
    return customBlockFromVue(vueTemplateCompiler, fileData, filePath, blockType);
}
function pluckVueFileCustomBlockSync(fileData, filePath, blockType) {
    const vueTemplateCompiler = loadVueCompilerSync();
    return customBlockFromVue(vueTemplateCompiler, fileData, filePath, blockType);
}
async function pluckSvelteFileScript(fileData) {
    let svelte2tsx;
    try {
        // eslint-disable-next-line import/no-extraneous-dependencies
        svelte2tsx = await Promise.resolve().then(() => tslib_1.__importStar(require('svelte2tsx')));
    }
    catch {
        throw MissingSvelteTemplateCompilerError;
    }
    return parseWithSvelte(svelte2tsx, fileData);
}
function pluckSvelteFileScriptSync(fileData) {
    let svelte2tsx;
    try {
        // eslint-disable-next-line import/no-extraneous-dependencies
        svelte2tsx = require('svelte2tsx');
    }
    catch {
        throw MissingSvelteTemplateCompilerError;
    }
    return parseWithSvelte(svelte2tsx, fileData);
}
async function pluckAstroFileScript(fileData) {
    let astroCompiler;
    try {
        // eslint-disable-next-line import/no-extraneous-dependencies
        astroCompiler = await Promise.resolve().then(() => tslib_1.__importStar(require('@astrojs/compiler')));
    }
    catch {
        throw MissingAstroCompilerError;
    }
    return parseWithAstro(astroCompiler, fileData);
}
function pluckAstroFileScriptSync(fileData) {
    let astroCompiler;
    try {
        // eslint-disable-next-line import/no-extraneous-dependencies
        astroCompiler = require('astrojs-compiler-sync');
    }
    catch {
        throw MissingAstroCompilerError;
    }
    return parseWithAstroSync(astroCompiler, fileData);
}
async function pluckGlimmerFileScript(fileData) {
    let contentTag;
    try {
        contentTag = await Promise.resolve().then(() => tslib_1.__importStar(require('content-tag')));
    }
    catch {
        throw MissingGlimmerCompilerError;
    }
    return transformGlimmerFile(contentTag, fileData);
}
function pluckGlimmerFileScriptSync(fileData) {
    let contentTag;
    try {
        contentTag = require('content-tag');
    }
    catch {
        throw MissingGlimmerCompilerError;
    }
    return transformGlimmerFile(contentTag, fileData);
}
