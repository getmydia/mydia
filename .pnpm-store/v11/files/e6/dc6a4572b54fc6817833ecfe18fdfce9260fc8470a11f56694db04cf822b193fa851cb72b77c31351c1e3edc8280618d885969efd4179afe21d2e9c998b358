import { Types } from '@graphql-codegen/plugin-helpers';
import { CodegenContext } from '../config.js';
export declare const createWatcher: (initialContext: CodegenContext, onNext: (result: Types.FileOutput[]) => Promise<Types.FileOutput[]>) => {
    /**
     * Call this function to stop the running watch server
     *
     * @returns Promise that resolves when watcher has terminated ({@link runningWatcher} promise settled)
     * */
    stopWatching: () => Promise<void>;
    /**
     * Promise that will never resolve as long as the watcher is running. To stop
     * the watcher, call {@link stopWatching}, which will send a stop signal and
     * then return a promise that doesn't resolve until `runningWatcher` has resolved.
     * */
    runningWatcher: Promise<void>;
};
