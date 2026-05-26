"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.init = init;
const helpers_js_1 = require("./helpers.js");
const questions_js_1 = require("./questions.js");
const targets_js_1 = require("./targets.js");
const types_js_1 = require("./types.js");
function log(...msgs) {
    // eslint-disable-next-line no-console
    console.log(...msgs);
}
async function init() {
    log(`
    Welcome to ${(0, helpers_js_1.bold)('GraphQL Code Generator')}!
    Answer few questions and we will setup everything for you.
  `);
    const possibleTargets = (0, targets_js_1.guessTargets)();
    const answers = await (0, questions_js_1.getAnswers)(possibleTargets);
    // define config
    const config = {
        overwrite: true,
        schema: answers.schema,
        ...(answers.targets.includes(types_js_1.Tags.client) ||
            answers.targets.includes(types_js_1.Tags.angular) ||
            answers.targets.includes(types_js_1.Tags.stencil)
            ? { documents: answers.documents }
            : {}),
        generates: {
            [answers.output]: {
                ...(answers.targets.includes(types_js_1.Tags.client) ? { preset: 'client' } : {}),
                plugins: answers.plugins ? answers.plugins.map(p => p.value) : [],
            },
        },
    };
    // introspection
    if (answers.introspection) {
        addIntrospection(config);
    }
    // config file
    const { relativePath } = await (0, helpers_js_1.writeConfig)(answers, config);
    log(`Fetching latest versions of selected plugins...`);
    // write package.json
    await (0, helpers_js_1.writePackage)(answers, relativePath);
    // Emit status to the terminal
    log(`
    Config file generated at ${(0, helpers_js_1.bold)(relativePath)}

      ${(0, helpers_js_1.bold)('$ npm install')}

    To install the plugins.

      ${(0, helpers_js_1.bold)(`$ npm run ${answers.script}`)}

    To run GraphQL Code Generator.
  `);
}
// adds an introspection to `generates`
function addIntrospection(config) {
    config.generates['./graphql.schema.json'] = {
        plugins: ['introspection'],
    };
}
