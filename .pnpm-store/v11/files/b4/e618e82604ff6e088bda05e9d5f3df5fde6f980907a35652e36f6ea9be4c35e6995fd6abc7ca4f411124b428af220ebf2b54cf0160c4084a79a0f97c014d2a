"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.debugLog = debugLog;
exports.printLogs = printLogs;
exports.resetLogs = resetLogs;
const logger_js_1 = require("./logger.js");
let queue = [];
function debugLog(message, ...meta) {
    queue.push({
        message,
        meta,
    });
}
function printLogs() {
    for (const log of queue) {
        (0, logger_js_1.getLogger)().info(log.message, ...log.meta);
    }
    resetLogs();
}
function resetLogs() {
    queue = [];
}
