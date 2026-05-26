"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.generate = generate;
const tslib_1 = require("tslib");
const crypto_1 = require("crypto");
const path_1 = require("path");
const log_symbols_1 = tslib_1.__importDefault(require("log-symbols"));
const codegen_js_1 = require("./codegen.js");
const config_js_1 = require("./config.js");
const hooks_js_1 = require("./hooks.js");
const debugging_js_1 = require("./utils/debugging.js");
const file_system_js_1 = require("./utils/file-system.js");
const logger_js_1 = require("./utils/logger.js");
const watcher_js_1 = require("./utils/watcher.js");
const hash = (content) => (0, crypto_1.createHash)('sha1').update(content).digest('base64');
async function generate(input, saveToFile = true) {
    const context = (0, config_js_1.ensureContext)(input);
    const config = context.getConfig();
    await context.profiler.run(() => (0, hooks_js_1.lifecycleHooks)(config.hooks).afterStart(), 'Lifecycle: afterStart');
    let previouslyGeneratedFilenames = [];
    function removeStaleFiles(config, generationResult) {
        const filenames = generationResult.map(o => o.filename);
        // find stale files from previous build which are not present in current build
        const staleFilenames = previouslyGeneratedFilenames.filter(f => !filenames.includes(f));
        for (const filename of staleFilenames) {
            if (shouldOverwrite(config, filename)) {
                (0, file_system_js_1.unlinkFile)(filename, err => {
                    const prettyFilename = filename.replace(`${input.cwd || process.cwd()}/`, '');
                    if (err) {
                        (0, debugging_js_1.debugLog)(`Cannot remove stale file: ${prettyFilename}\n${err}`);
                    }
                    else {
                        (0, debugging_js_1.debugLog)(`Removed stale file: ${prettyFilename}`);
                    }
                });
            }
        }
        previouslyGeneratedFilenames = filenames;
    }
    const recentOutputHash = new Map();
    async function writeOutput(generationResult) {
        if (!saveToFile) {
            return generationResult;
        }
        if (config.watch) {
            removeStaleFiles(config, generationResult);
        }
        await context.profiler.run(async () => {
            await (0, hooks_js_1.lifecycleHooks)(config.hooks).beforeAllFileWrite(generationResult.map(r => r.filename));
        }, 'Lifecycle: beforeAllFileWrite');
        await context.profiler.run(() => Promise.all(generationResult.map(async (result) => {
            const previousHash = recentOutputHash.get(result.filename) || (await hashFile(result.filename));
            const exists = previousHash !== null;
            // Store previous hash to avoid reading from disk again
            if (previousHash) {
                recentOutputHash.set(result.filename, previousHash);
            }
            if (!shouldOverwrite(config, result.filename) && exists) {
                return;
            }
            let content = result.content || '';
            const currentHash = hash(content);
            if (previousHash && currentHash === previousHash) {
                (0, debugging_js_1.debugLog)(`Skipping file (${result.filename}) writing due to indentical hash...`);
                return;
            }
            // skip updating file in dry mode
            if (context.checkMode) {
                context.checkModeStaleFiles.push(result.filename);
                return;
            }
            if (content.length === 0) {
                return;
            }
            const absolutePath = (0, path_1.isAbsolute)(result.filename)
                ? result.filename
                : (0, path_1.join)(input.cwd || process.cwd(), result.filename);
            const basedir = (0, path_1.dirname)(absolutePath);
            await (0, file_system_js_1.mkdirp)(basedir);
            content = await (0, hooks_js_1.lifecycleHooks)(result.hooks).beforeOneFileWrite(absolutePath, content);
            content = await (0, hooks_js_1.lifecycleHooks)(config.hooks).beforeOneFileWrite(absolutePath, content);
            if (content !== result.content) {
                result.content = content;
                // compare the prettified content with the previous hash
                // to compare the content with an existing prettified file
                if (hash(content) === previousHash) {
                    (0, debugging_js_1.debugLog)(`Skipping file (${result.filename}) writing due to indentical hash after prettier...`);
                    // the modified content is NOT stored in recentOutputHash
                    // so a diff can already be detected before executing the hook
                    return;
                }
            }
            await (0, file_system_js_1.writeFile)(absolutePath, result.content);
            recentOutputHash.set(result.filename, currentHash);
            await (0, hooks_js_1.lifecycleHooks)(result.hooks).afterOneFileWrite(result.filename);
            await (0, hooks_js_1.lifecycleHooks)(config.hooks).afterOneFileWrite(result.filename);
        })), 'Write files');
        await context.profiler.run(() => (0, hooks_js_1.lifecycleHooks)(config.hooks).afterAllFileWrite(generationResult.map(r => r.filename)), 'Lifecycle: afterAllFileWrite');
        return generationResult;
    }
    // watch mode
    if (config.watch) {
        return (0, watcher_js_1.createWatcher)(context, writeOutput).runningWatcher;
    }
    const { result: outputFiles, error } = await context.profiler.run(() => (0, codegen_js_1.executeCodegen)(context), 'executeCodegen');
    if (error) {
        // If all generation failed, just throw to return non-zero code.
        if (outputFiles.length === 0) {
            throw error;
        }
        // If partial success, but partial output is not allowed, throw to return non-zero code.
        if (!config.allowPartialOutputs) {
            (0, logger_js_1.getLogger)().error(`  ${log_symbols_1.default.error} One or more errors occurred, no files were generated. To allow output on errors, set config.allowPartialOutputs=true`);
            throw error;
        }
        // If partial success, and partial output is allowed, warn and proceed to write to files.
        (0, logger_js_1.getLogger)().warn(`  ${log_symbols_1.default.warning} One or more errors occurred, some files were generated. To prevent any output on errors, set config.allowPartialOutputs=false`);
    }
    await context.profiler.run(() => writeOutput(outputFiles), 'writeOutput');
    await context.profiler.run(() => (0, hooks_js_1.lifecycleHooks)(config.hooks).beforeDone(), 'Lifecycle: beforeDone');
    if (context.profilerOutput) {
        await (0, file_system_js_1.writeFile)((0, path_1.join)(context.cwd, context.profilerOutput), JSON.stringify(context.profiler.collect()));
    }
    return outputFiles;
}
function shouldOverwrite(config, outputPath) {
    const globalValue = config.overwrite === undefined ? true : !!config.overwrite;
    const outputConfig = config.generates[outputPath];
    if (!outputConfig) {
        (0, debugging_js_1.debugLog)(`Couldn't find a config of ${outputPath}`);
        return globalValue;
    }
    if (isConfiguredOutput(outputConfig) && typeof outputConfig.overwrite === 'boolean') {
        return outputConfig.overwrite;
    }
    return globalValue;
}
function isConfiguredOutput(output) {
    return typeof output.plugins !== 'undefined';
}
async function hashFile(filePath) {
    try {
        return hash(await (0, file_system_js_1.readFile)(filePath));
    }
    catch (err) {
        if (err && err.code === 'ENOENT') {
            // return null if file does not exist
            return null;
        }
        // rethrow unexpected errors
        throw err;
    }
}
