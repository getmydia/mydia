"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.useQueue = useQueue;
exports.useSyncQueue = useSyncQueue;
const tslib_1 = require("tslib");
const p_limit_1 = tslib_1.__importDefault(require("p-limit"));
function useQueue(options) {
    const queue = [];
    const limit = options?.concurrency
        ? (0, p_limit_1.default)(options.concurrency)
        : async (fn) => fn();
    return {
        add(fn) {
            queue.push(() => limit(fn));
        },
        runAll() {
            return Promise.all(queue.map(fn => fn()));
        },
    };
}
function useSyncQueue() {
    const queue = [];
    return {
        add(fn) {
            queue.push(fn);
        },
        runAll() {
            for (const fn of queue) {
                fn();
            }
        },
    };
}
