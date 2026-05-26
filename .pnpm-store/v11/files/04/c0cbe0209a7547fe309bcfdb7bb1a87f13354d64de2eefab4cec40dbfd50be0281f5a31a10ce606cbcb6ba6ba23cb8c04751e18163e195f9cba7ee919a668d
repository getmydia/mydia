"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createWatcher = void 0;
const tslib_1 = require("tslib");
const path_1 = require("path");
const debounce_1 = tslib_1.__importDefault(require("debounce"));
const log_symbols_1 = tslib_1.__importDefault(require("log-symbols"));
const micromatch_1 = tslib_1.__importDefault(require("micromatch"));
const plugin_helpers_1 = require("@graphql-codegen/plugin-helpers");
const codegen_js_1 = require("../codegen.js");
const config_js_1 = require("../config.js");
const hooks_js_1 = require("../hooks.js");
const debugging_js_1 = require("./debugging.js");
const file_system_js_1 = require("./file-system.js");
const logger_js_1 = require("./logger.js");
const patterns_js_1 = require("./patterns.js");
function log(msg) {
    // double spaces to inline the message with Listr
    (0, logger_js_1.getLogger)().info(`  ${msg}`);
}
function emitWatching(watchDir) {
    log(`${log_symbols_1.default.info} Watching for changes in ${watchDir}...`);
}
const createWatcher = (initialContext, onNext) => {
    (0, debugging_js_1.debugLog)(`[Watcher] Starting watcher...`);
    let config = initialContext.getConfig();
    const globalPatternSet = (0, patterns_js_1.makeGlobalPatternSet)(initialContext);
    const localPatternSets = Object.keys(config.generates)
        .map(filename => (0, plugin_helpers_1.normalizeOutputParam)(config.generates[filename]))
        .map(conf => (0, patterns_js_1.makeLocalPatternSet)(conf));
    const allAffirmativePatterns = (0, patterns_js_1.allAffirmativePatternsFromPatternSets)([
        globalPatternSet,
        ...localPatternSets,
    ]);
    const shouldRebuild = (0, patterns_js_1.makeShouldRebuild)({
        globalPatternSet,
        localPatternSets,
    });
    let watcherSubscription;
    const runWatcher = async (abortSignal) => {
        const watchDirectory = await findHighestCommonDirectory(allAffirmativePatterns);
        // Try to load the parcel watcher, but don't fail if it's not available.
        let parcelWatcher;
        try {
            parcelWatcher = await Promise.resolve().then(() => tslib_1.__importStar(require('@parcel/watcher')));
        }
        catch {
            log('Failed to import @parcel/watcher.\n  To use watch mode, install https://www.npmjs.com/package/@parcel/watcher.');
            return;
        }
        (0, debugging_js_1.debugLog)(`[Watcher] Parcel watcher loaded...`);
        let isShutdown = false;
        const debouncedExec = (0, debounce_1.default)(() => {
            if (!isShutdown) {
                (0, codegen_js_1.executeCodegen)(initialContext)
                    .then(({ result, error }) => {
                    // FIXME: this is a quick fix to stop `onNext` (writeOutput) from
                    // removing all files when there is an error.
                    //
                    // This is because `removeStaleFiles()` will remove files if the
                    // generated files are different between runs. And on error, it
                    // returns an empty array i.e. will remove all generated files from
                    // the previous run
                    //
                    // This also means we don't have config.allowPartialOutputs in watch mode
                    if (error) {
                        return;
                    }
                    onNext(result);
                }, () => Promise.resolve())
                    .then(() => emitWatching(watchDirectory));
            }
        }, 100);
        emitWatching(watchDirectory);
        const ignored = ['**/.git/**'];
        for (const entry of Object.keys(config.generates).map(filename => ({
            filename,
            config: (0, plugin_helpers_1.normalizeOutputParam)(config.generates[filename]),
        }))) {
            // ParcelWatcher expects relative ignore patterns to be relative from watchDirectory,
            // but we expect filename from config to be relative from cwd, so we need to convert
            const filenameRelativeFromWatchDirectory = (0, path_1.relative)(watchDirectory, (0, path_1.resolve)(process.cwd(), entry.filename));
            if (entry.config.preset) {
                const extension = entry.config.presetConfig?.extension;
                if (extension) {
                    ignored.push((0, path_1.join)(filenameRelativeFromWatchDirectory, '**', '*' + extension));
                }
            }
            else {
                ignored.push(filenameRelativeFromWatchDirectory);
            }
        }
        watcherSubscription = await parcelWatcher.subscribe(watchDirectory, async (_, events) => {
            // it doesn't matter what has changed, need to run whole process anyway
            await Promise.all(
            // NOTE: @parcel/watcher always provides path as an absolute path
            events.map(async ({ type: eventName, path }) => {
                if (!shouldRebuild({ path })) {
                    return;
                }
                (0, hooks_js_1.lifecycleHooks)(config.hooks).onWatchTriggered(eventName, path);
                (0, debugging_js_1.debugLog)(`[Watcher] triggered due to a file ${eventName} event: ${path}`);
                // In ESM require is not defined
                try {
                    delete require.cache[path];
                }
                catch { }
                if (eventName === 'update' && config.configFilePath && path === config.configFilePath) {
                    log(`${log_symbols_1.default.info} Config file has changed, reloading...`);
                    const context = await (0, config_js_1.loadContext)(config.configFilePath);
                    const newParsedConfig = context.getConfig();
                    newParsedConfig.watch = config.watch;
                    newParsedConfig.silent = config.silent;
                    newParsedConfig.overwrite = config.overwrite;
                    newParsedConfig.configFilePath = config.configFilePath;
                    config = newParsedConfig;
                    initialContext.updateConfig(config);
                }
                debouncedExec();
            }));
        }, { ignore: ignored });
        (0, debugging_js_1.debugLog)(`[Watcher] Started`);
        const shutdown = (
        /** Optional callback to execute after shutdown has completed its async tasks */
        afterShutdown) => {
            isShutdown = true;
            (0, debugging_js_1.debugLog)(`[Watcher] Shutting down`);
            log(`Shutting down watch...`);
            const pendingUnsubscribe = watcherSubscription.unsubscribe();
            const pendingBeforeDoneHook = (0, hooks_js_1.lifecycleHooks)(config.hooks).beforeDone();
            if (afterShutdown && typeof afterShutdown === 'function') {
                Promise.allSettled([pendingUnsubscribe, pendingBeforeDoneHook]).then(afterShutdown);
            }
        };
        abortSignal.addEventListener('abort', () => shutdown(abortSignal.reason));
        process.once('SIGINT', () => shutdown());
        process.once('SIGTERM', () => shutdown());
    };
    // Use an AbortController for shutdown signals
    // NOTE: This will be polyfilled on Node 14 (or any environment without it defined)
    const abortController = new AbortController();
    /**
     * Send shutdown signal and return a promise that only resolves after the
     * runningWatcher has resolved, which only resolved after the shutdown signal has been handled
     */
    const stopWatching = async function () {
        // stopWatching.afterShutdown is lazily set to resolve pendingShutdown promise
        abortController.abort(stopWatching.afterShutdown);
        // SUBTLE: runningWatcher waits for pendingShutdown before it resolves itself, so
        // by awaiting it here, we are awaiting both the shutdown handler, and runningWatcher itself
        await stopWatching.runningWatcher;
    };
    stopWatching.afterShutdown = () => {
        (0, debugging_js_1.debugLog)('Shutdown watcher before it started');
    };
    stopWatching.runningWatcher = Promise.resolve();
    /** Promise will resolve after the shutdown() handler completes */
    const pendingShutdown = new Promise(afterShutdown => {
        // afterShutdown will be passed to shutdown() handler via abortSignal.reason
        stopWatching.afterShutdown = afterShutdown;
    });
    /**
     * Promise that resolves after the watch server has shutdown, either because
     * stopWatching() was called or there was an error inside it
     */
    stopWatching.runningWatcher = new Promise((resolve, reject) => {
        (0, codegen_js_1.executeCodegen)(initialContext)
            .then(({ result, error }) => {
            // TODO: this is the initial run, the logic here mimics the above watcher logic.
            // We need to check whether it's ok to deviate between these two.
            if (error) {
                return;
            }
            onNext(result);
        }, () => Promise.resolve())
            .then(() => runWatcher(abortController.signal))
            .catch(err => {
            watcherSubscription.unsubscribe();
            reject(err);
        })
            .then(() => pendingShutdown)
            .finally(() => {
            (0, debugging_js_1.debugLog)('Done watching.');
            resolve();
        });
    });
    return {
        stopWatching,
        runningWatcher: stopWatching.runningWatcher,
    };
};
exports.createWatcher = createWatcher;
/**
 * Given a list of file paths (each of which may be absolute, or relative from
 * `process.cwd()`), find absolute path of the "highest" common directory,
 * i.e. the directory that contains all the files in the list.
 *
 * @param files List of relative and/or absolute file paths (or micromatch patterns)
 */
const findHighestCommonDirectory = async (files) => {
    // Map files to a list of basePaths, where "base" is the result of mm.scan(pathOrPattern)
    // e.g. mm.scan("/**/foo/bar").base -> "/" ; mm.scan("/foo/bar/**/fizz/*.graphql") -> /foo/bar
    const dirPaths = files
        .map(filePath => ((0, path_1.isAbsolute)(filePath) ? filePath : (0, path_1.resolve)(filePath)))
        // mm.scan doesn't know how to handle Windows \ path separator
        .map(patterned => patterned.replace(/\\/g, '/'))
        .map(patterned => micromatch_1.default.scan(patterned).base)
        // revert the separators to the platform-supported ones
        .map(base => base.replace(/\//g, path_1.sep));
    // Return longest common prefix if it's accessible, otherwise process.cwd()
    return (async (maybeValidPath) => {
        (0, debugging_js_1.debugLog)(`[Watcher] Longest common prefix of all files: ${maybeValidPath}...`);
        try {
            await (0, file_system_js_1.access)(maybeValidPath);
            return maybeValidPath;
        }
        catch {
            log(`[Watcher] Longest common prefix (${maybeValidPath}) is not accessible`);
            log(`[Watcher] Watching current working directory (${process.cwd()}) instead`);
            return process.cwd();
        }
    })(longestCommonPrefix(dirPaths.map(path => path.split(path_1.sep))).join(path_1.sep));
};
/**
 * Find the longest common prefix of an array of paths, where each item in
 * the array an array of path segments which comprise an absolute path when
 * joined together by a path separator
 *
 * Adapted from:
 * https://duncan-mcardle.medium.com/leetcode-problem-14-longest-common-prefix-javascript-3bc6a2f777c4
 *
 * @param splitPaths An array of arrays, where each item is a path split by its separator
 * @returns An array of path segments representing the longest common prefix of splitPaths
 */
const longestCommonPrefix = (splitPaths) => {
    // Return early on empty input
    if (!splitPaths.length) {
        return [];
    }
    // Loop through the segments of the first path
    for (let i = 0; i <= splitPaths[0].length; i++) {
        // Check if this path segment is present in the same position of every path
        if (!splitPaths.every(string => string[i] === splitPaths[0][i])) {
            // If not, return the path segments up to and including the previous segment
            return splitPaths[0].slice(0, i);
        }
    }
    return splitPaths[0];
};
