import { exec } from 'child_process';
import { delimiter, sep } from 'path';
import { quote } from 'shell-quote';
import { debugLog } from './utils/debugging.js';
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
        exec(cmd, {
            env: {
                ...process.env,
                PATH: `${process.env.PATH}${delimiter}${process.cwd()}${sep}node_modules${sep}.bin`,
            },
        }, (error, stdout, stderr) => {
            if (error) {
                reject(error);
                // eslint-disable-next-line no-console
                console.error(error);
            }
            else {
                debugLog(stdout || stderr);
                resolve(stdout || stderr);
            }
        });
    });
}
async function executeHooks(hookName, _scripts = [], args = [], initialState) {
    debugLog(`Running lifecycle hook "${hookName}" scripts...`);
    let state = initialState;
    const scripts = Array.isArray(_scripts) ? _scripts : [_scripts];
    const quotedArgs = quote(args);
    for (const script of scripts) {
        if (typeof script === 'string') {
            debugLog(`Running lifecycle hook "${hookName}" script: ${script} with args: ${quotedArgs}...`);
            await execShellCommand(`${script} ${quotedArgs}`);
        }
        else {
            debugLog(`Running lifecycle hook "${hookName}" script: ${script.name} with args: ${args.join(' ')}...`);
            const hookArgs = state === undefined ? args : [...args, state];
            const hookResult = await script(...hookArgs);
            if (typeof hookResult === 'string' && typeof state === 'string') {
                debugLog(`Received new content from lifecycle hook "${hookName}" script: ${script.name}`);
                state = hookResult;
            }
        }
    }
    return state;
}
export const lifecycleHooks = (_hooks = {}) => {
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
