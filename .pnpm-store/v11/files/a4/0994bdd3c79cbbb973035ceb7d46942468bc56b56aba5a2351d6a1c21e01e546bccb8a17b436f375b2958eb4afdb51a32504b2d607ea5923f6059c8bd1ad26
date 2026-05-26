import { dummyLogger } from 'ts-log';
let logger;
export function getLogger() {
    return logger || dummyLogger;
}
useWinstonLogger();
export function setLogger(newLogger) {
    logger = newLogger;
}
export function setSilentLogger() {
    logger = dummyLogger;
}
export function useWinstonLogger() {
    if (logger?.levels) {
        return;
    }
    logger = console;
}
