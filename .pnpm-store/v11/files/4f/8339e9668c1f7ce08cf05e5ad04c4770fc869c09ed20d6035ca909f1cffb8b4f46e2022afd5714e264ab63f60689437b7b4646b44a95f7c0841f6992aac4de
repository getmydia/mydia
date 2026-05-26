import { getLogger } from './logger.js';
let queue = [];
export function debugLog(message, ...meta) {
    queue.push({
        message,
        meta,
    });
}
export function printLogs() {
    for (const log of queue) {
        getLogger().info(log.message, ...log.meta);
    }
    resetLogs();
}
export function resetLogs() {
    queue = [];
}
