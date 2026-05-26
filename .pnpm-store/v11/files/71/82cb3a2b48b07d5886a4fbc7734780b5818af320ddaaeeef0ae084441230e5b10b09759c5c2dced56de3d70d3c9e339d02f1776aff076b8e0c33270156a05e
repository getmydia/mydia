"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.guessTargets = guessTargets;
const fs_1 = require("fs");
const path_1 = require("path");
const types_js_1 = require("./types.js");
function guessTargets() {
    const pkg = JSON.parse((0, fs_1.readFileSync)((0, path_1.resolve)(process.cwd(), 'package.json'), 'utf8'));
    const dependencies = Object.keys({
        ...pkg.dependencies,
        ...pkg.devDependencies,
    });
    return {
        [types_js_1.Tags.angular]: isAngular(dependencies),
        [types_js_1.Tags.react]: isReact(dependencies),
        [types_js_1.Tags.stencil]: isStencil(dependencies),
        [types_js_1.Tags.vue]: isVue(dependencies),
        [types_js_1.Tags.client]: false,
        [types_js_1.Tags.node]: false,
        [types_js_1.Tags.typescript]: isTypescript(dependencies),
        [types_js_1.Tags.flow]: isFlow(dependencies),
        [types_js_1.Tags.graphqlRequest]: isGraphqlRequest(dependencies),
    };
}
function isAngular(dependencies) {
    return dependencies.includes('@angular/core');
}
function isReact(dependencies) {
    return dependencies.includes('react');
}
function isStencil(dependencies) {
    return dependencies.includes('@stencil/core');
}
function isVue(dependencies) {
    return dependencies.includes('vue') || dependencies.includes('nuxt');
}
function isTypescript(dependencies) {
    return dependencies.includes('typescript');
}
function isFlow(dependencies) {
    return dependencies.includes('flow');
}
function isGraphqlRequest(dependencies) {
    return dependencies.includes('graphql-request');
}
