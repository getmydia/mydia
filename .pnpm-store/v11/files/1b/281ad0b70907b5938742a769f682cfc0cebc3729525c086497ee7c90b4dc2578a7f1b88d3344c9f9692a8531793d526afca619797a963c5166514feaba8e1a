"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.writeConfig = writeConfig;
exports.writePackage = writePackage;
exports.bold = bold;
exports.grey = grey;
exports.italic = italic;
const tslib_1 = require("tslib");
const fs_1 = require("fs");
const path_1 = require("path");
const chalk_1 = tslib_1.__importDefault(require("chalk"));
const detect_indent_1 = tslib_1.__importDefault(require("detect-indent"));
const generator_1 = tslib_1.__importDefault(require("@babel/generator"));
const template_1 = tslib_1.__importDefault(require("@babel/template"));
const t = tslib_1.__importStar(require("@babel/types"));
const get_latest_version_js_1 = require("../utils/get-latest-version.js");
const types_js_1 = require("./types.js");
function jsObjectToBabelObjectExpression(obj) {
    const objExp = t.objectExpression([]);
    for (const [key, val] of Object.entries(obj)) {
        if (Array.isArray(val)) {
            objExp.properties.push(t.objectProperty(/^[a-zA-Z0-9]+$/.test(key) ? t.identifier(key) : t.stringLiteral(key), t.arrayExpression(val.map(v => typeof v === 'object'
                ? jsObjectToBabelObjectExpression(v)
                : t.valueToNode(v)))));
        }
        else {
            objExp.properties.push(t.objectProperty(/^[a-zA-Z0-9]+$/.test(key) ? t.identifier(key) : t.stringLiteral(key), typeof val === 'object'
                ? jsObjectToBabelObjectExpression(val)
                : t.valueToNode(val)));
        }
    }
    return objExp;
}
// Parses config and writes it to a file
async function writeConfig(answers, config) {
    const YAML = await Promise.resolve().then(() => tslib_1.__importStar(require('json-to-pretty-yaml'))).then(m => ('default' in m ? m.default : m));
    const ext = answers.config.toLocaleLowerCase().split('.')[1];
    const fullPath = (0, path_1.resolve)(process.cwd(), answers.config);
    const relativePath = (0, path_1.relative)(process.cwd(), answers.config);
    let content;
    if (ext === 'ts') {
        const buildRequire = template_1.default.statement(`%%config%%`);
        const ast = buildRequire({
            config: jsObjectToBabelObjectExpression(config),
        });
        content = `
import type { CodegenConfig } from '@graphql-codegen/cli';

const config: CodegenConfig = ${(0, generator_1.default)(ast).code.replace(/\(|\)/g, '')}

export default config;
`;
    }
    else {
        content = ext === 'json' ? JSON.stringify(config) : YAML.stringify(config);
    }
    (0, fs_1.writeFileSync)(fullPath, content, 'utf8');
    return {
        relativePath,
        fullPath,
    };
}
// Updates package.json (script and plugins as dependencies)
async function writePackage(answers, configLocation) {
    // script
    const pkgPath = (0, path_1.resolve)(process.cwd(), 'package.json');
    const pkgContent = (0, fs_1.readFileSync)(pkgPath, 'utf8');
    const pkg = JSON.parse(pkgContent);
    const { indent } = (0, detect_indent_1.default)(pkgContent);
    pkg.scripts ||= {};
    pkg.scripts[answers.script] = `graphql-codegen --config ${configLocation}`;
    // plugin
    pkg.devDependencies ||= {};
    await Promise.all((answers.plugins || []).map(async (plugin) => {
        pkg.devDependencies[plugin.package] = await (0, get_latest_version_js_1.getLatestVersion)(plugin.package);
    }));
    if (answers.introspection) {
        pkg.devDependencies['@graphql-codegen/introspection'] = await (0, get_latest_version_js_1.getLatestVersion)('@graphql-codegen/introspection');
    }
    pkg.devDependencies['@graphql-codegen/cli'] = await (0, get_latest_version_js_1.getLatestVersion)('@graphql-codegen/cli');
    if (answers.targets.includes(types_js_1.Tags.client)) {
        pkg.devDependencies['@graphql-codegen/client-preset'] = await (0, get_latest_version_js_1.getLatestVersion)('@graphql-codegen/client-preset');
    }
    (0, fs_1.writeFileSync)(pkgPath, JSON.stringify(pkg, null, indent));
}
function bold(str) {
    return chalk_1.default.bold(str);
}
function grey(str) {
    return chalk_1.default.grey(str);
}
function italic(str) {
    return chalk_1.default.italic(str);
}
