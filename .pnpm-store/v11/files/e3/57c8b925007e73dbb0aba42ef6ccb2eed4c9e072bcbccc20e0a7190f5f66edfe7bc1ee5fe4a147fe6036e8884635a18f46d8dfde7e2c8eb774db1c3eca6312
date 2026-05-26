"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getAnswers = getAnswers;
exports.getApplicationTypeChoices = getApplicationTypeChoices;
exports.getPluginChoices = getPluginChoices;
const prompts_1 = require("@inquirer/prompts");
const helpers_js_1 = require("./helpers.js");
const plugins_js_1 = require("./plugins.js");
const types_js_1 = require("./types.js");
async function getAnswers(possibleTargets) {
    try {
        const targetChoices = getApplicationTypeChoices(possibleTargets);
        const targets = await (0, prompts_1.select)({
            message: `What type of application are you building?`,
            choices: targetChoices,
            default: targetChoices.find(c => c.checked)?.value,
        });
        const schema = await (0, prompts_1.input)({
            message: `Where is your schema?: ${(0, helpers_js_1.grey)('(path or url)')}`,
            default: 'http://localhost:4000', // matches Apollo Server's default
            validate: str => str.length > 0,
        });
        let documents;
        if (targets.includes(types_js_1.Tags.client) ||
            targets.includes(types_js_1.Tags.angular) ||
            targets.includes(types_js_1.Tags.stencil))
            documents = await (0, prompts_1.input)({
                message: 'Where are your operations and fragments?:',
                default: getDocumentsDefaultValue(targets),
                validate: str => str.length > 0,
            });
        let plugins;
        if (!targets.includes(types_js_1.Tags.client)) {
            plugins = await (0, prompts_1.checkbox)({
                message: 'Pick plugins:',
                choices: getPluginChoices(targets),
                validate: plugins => plugins.length > 0,
            });
        }
        const output = await (0, prompts_1.input)({
            message: 'Where to write the output:',
            default: getOutputDefaultValue({ targets, plugins }),
            validate: str => str.length > 0,
        });
        const introspection = await (0, prompts_1.confirm)({
            message: 'Do you want to generate an introspection file?',
            default: false,
        });
        const config = await (0, prompts_1.input)({
            message: 'How to name the config file?',
            default: (() => targets.includes(types_js_1.Tags.client) ||
                targets.includes(types_js_1.Tags.typescript) ||
                targets.includes(types_js_1.Tags.angular)
                ? 'codegen.ts'
                : 'codegen.yml')(),
            validate: str => {
                const isNotEmpty = str.length > 0;
                const hasCorrectExtension = ['json', 'yml', 'yaml', 'js', 'ts'].some(ext => str.toLocaleLowerCase().endsWith(`.${ext}`));
                return isNotEmpty && hasCorrectExtension;
            },
        });
        const script = await (0, prompts_1.input)({
            default: 'codegen',
            message: 'What script in package.json should run the codegen?',
            validate: (str) => str.length > 0,
        });
        return {
            targets,
            schema,
            documents,
            plugins,
            output,
            introspection,
            config,
            script,
        };
    }
    catch (error) {
        if (error instanceof Error && error.name === 'ExitPromptError') {
            // This error because user exited using CMD+C, just exit gracefully or else user would see an ugly error message
            // https://github.com/SBoudrias/Inquirer.js/blob/ee16061a1e3f99a6cc714a3d473f7cd12b06a3f1/packages/prompts/README.md#handling-ctrlc-gracefully
            process.exit();
        }
        else {
            throw error;
        }
    }
}
function getApplicationTypeChoices(possibleTargets) {
    function withFlowOrTypescript(tags) {
        if (possibleTargets.TypeScript) {
            tags.push(types_js_1.Tags.typescript);
        }
        else if (possibleTargets.Flow) {
            tags.push(types_js_1.Tags.flow);
        }
        else if (possibleTargets.Node) {
            tags.push(types_js_1.Tags.typescript, types_js_1.Tags.flow);
        }
        return tags;
    }
    return [
        {
            name: 'Backend - API or server',
            key: 'backend',
            value: withFlowOrTypescript([types_js_1.Tags.node]),
            checked: possibleTargets.Node,
        },
        {
            name: 'Application built with Angular',
            key: 'angular',
            value: [types_js_1.Tags.angular],
            checked: possibleTargets.Angular,
        },
        {
            name: 'Application built with React',
            key: 'react',
            value: withFlowOrTypescript([types_js_1.Tags.react, types_js_1.Tags.client]),
            checked: possibleTargets.React,
        },
        {
            name: 'Application built with Stencil',
            key: 'stencil',
            value: [types_js_1.Tags.stencil, types_js_1.Tags.typescript],
            checked: possibleTargets.Stencil,
        },
        {
            name: 'Application built with Vue',
            key: 'vue',
            value: [types_js_1.Tags.vue, types_js_1.Tags.client],
            checked: possibleTargets.Vue,
        },
        {
            name: 'Application using graphql-request',
            key: 'graphqlRequest',
            value: [types_js_1.Tags.graphqlRequest, types_js_1.Tags.client],
            checked: possibleTargets.graphqlRequest,
        },
        {
            name: 'Application built with other framework or vanilla JS',
            key: 'client',
            value: [types_js_1.Tags.typescript, types_js_1.Tags.flow],
            checked: possibleTargets.Browser &&
                !possibleTargets.Angular &&
                !possibleTargets.React &&
                !possibleTargets.Stencil,
        },
    ];
}
function getPluginChoices(targets) {
    return plugins_js_1.plugins
        .filter(p => p.available(targets))
        .map(p => {
        return {
            name: p.name,
            value: p,
            checked: p.shouldBeSelected(targets),
        };
    });
}
function getOutputDefaultValue({ targets, plugins }) {
    if (targets.includes(types_js_1.Tags.client)) {
        return 'src/gql/';
    }
    if (plugins.some(plugin => plugin.defaultExtension === '.tsx')) {
        return 'src/generated/graphql.tsx';
    }
    if (plugins.some(plugin => plugin.defaultExtension === '.ts')) {
        return 'src/generated/graphql.ts';
    }
    return 'src/generated/graphql.js';
}
function getDocumentsDefaultValue(targets) {
    if (targets.includes(types_js_1.Tags.vue)) {
        return 'src/**/*.vue';
    }
    if (targets.includes(types_js_1.Tags.angular)) {
        return 'src/**/*.ts';
    }
    if (targets.includes(types_js_1.Tags.client)) {
        return 'src/**/*.tsx';
    }
    return 'src/**/*.graphql';
}
