"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.lifecycleHooks = void 0;
const child_process_1 = require("child_process");
const path_1 = require("path");
const shell_quote_1 = require("shell-quote");
const debugging_js_1 = require("./utils/debugging.js");
const DEFAULT_HOOKS = {
    afterStart: [],
    beforeDone: [],
    onWatchTriggered: [],
    onError: [],
    afterOneFileWrite: [],
    afterAllFileWrite: [],
    beforeOneFileWrite: [],
    beforeAllFileWrite: [],
};
function execShellCommand(cmd) {
    return new Promise((resolve, reject) => {
        (0, child_process_1.exec)(cmd, {
            env: {
                ...process.env,
                PATH: `${process.env.PATH}${path_1.delimiter}${process.cwd()}${path_1.sep}node_modules${path_1.sep}.bin`,
            },
        }, (error, stdout, stderr) => {
            if (error) {
                reject(error);
                // eslint-disable-next-line no-console
                console.error(error);
            }
            else {
                (0, debugging_js_1.debugLog)(stdout || stderr);
                resolve(stdout || stderr);
            }
        });
    });
}
async function executeHooks(hookName, _scripts = [], args = [], initialState) {
    (0, debugging_js_1.debugLog)(`Running lifecycle hook "${hookName}" scripts...`);
    let state = initialState;
    const scripts = Array.isArray(_scripts) ? _scripts : [_scripts];
    const quotedArgs = (0, shell_quote_1.quote)(args);
    for (const script of scripts) {
        if (typeof script === 'string') {
            (0, debugging_js_1.debugLog)(`Running lifecycle hook "${hookName}" script: ${script} with args: ${quotedArgs}...`);
            await execShellCommand(`${script} ${quotedArgs}`);
        }
        else {
            (0, debugging_js_1.debugLog)(`Running lifecycle hook "${hookName}" script: ${script.name} with args: ${args.join(' ')}...`);
            const hookArgs = state === undefined ? args : [...args, state];
            const hookResult = await script(...hookArgs);
            if (typeof hookResult === 'string' && typeof state === 'string') {
                (0, debugging_js_1.debugLog)(`Received new content from lifecycle hook "${hookName}" script: ${script.name}`);
                state = hookResult;
            }
        }
    }
    return state;
}
const lifecycleHooks = (_hooks = {}) => {
    const hooks = {
        ...DEFAULT_HOOKS,
        ..._hooks,
    };
    return {
        afterStart: async () => {
            await executeHooks('afterStart', hooks.afterStart);
        },
        onWatchTriggered: async (event, path) => {
            await executeHooks('onWatchTriggered', hooks.onWatchTriggered, [event, path]);
        },
        onError: async (error) => {
            await executeHooks('onError', hooks.onError, [error]);
        },
        afterOneFileWrite: async (path) => {
            await executeHooks('afterOneFileWrite', hooks.afterOneFileWrite, [path]);
        },
        afterAllFileWrite: async (paths) => {
            await executeHooks('afterAllFileWrite', hooks.afterAllFileWrite, paths);
        },
        beforeOneFileWrite: async (path, content) => {
            const result = await executeHooks('beforeOneFileWrite', hooks.beforeOneFileWrite, [path], content);
            return typeof result === 'string' ? result : content;
        },
        beforeAllFileWrite: async (paths) => {
            await executeHooks('beforeAllFileWrite', hooks.beforeAllFileWrite, paths);
        },
        beforeDone: async () => {
            await executeHooks('beforeDone', hooks.beforeDone);
        },
    };
};
exports.lifecycleHooks = lifecycleHooks;
