import { readFileSync } from 'fs';
import { resolve } from 'path';
import { Tags } from './types.js';
export function guessTargets() {
    const pkg = JSON.parse(readFileSync(resolve(process.cwd(), 'package.json'), 'utf8'));
    const dependencies = Object.keys({
        ...pkg.dependencies,
        ...pkg.devDependencies,
    });
    return {
        [Tags.angular]: isAngular(dependencies),
        [Tags.react]: isReact(dependencies),
        [Tags.stencil]: isStencil(dependencies),
        [Tags.vue]: isVue(dependencies),
        [Tags.client]: false,
        [Tags.node]: false,
        [Tags.typescript]: isTypescript(dependencies),
        [Tags.flow]: isFlow(dependencies),
        [Tags.graphqlRequest]: isGraphqlRequest(dependencies),
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
