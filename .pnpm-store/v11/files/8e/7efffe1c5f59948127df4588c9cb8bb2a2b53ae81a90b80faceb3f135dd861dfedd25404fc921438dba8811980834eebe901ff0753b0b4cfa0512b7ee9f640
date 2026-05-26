"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getLogger = getLogger;
exports.setLogger = setLogger;
exports.setSilentLogger = setSilentLogger;
exports.useWinstonLogger = useWinstonLogger;
const ts_log_1 = require("ts-log");
let logger;
function getLogger() {
    return logger || ts_log_1.dummyLogger;
}
useWinstonLogger();
function setLogger(newLogger) {
    logger = newLogger;
}
function setSilentLogger() {
    logger = ts_log_1.dummyLogger;
}
function useWinstonLogger() {
    if (logger?.levels) {
        return;
    }
    logger = console;
}
