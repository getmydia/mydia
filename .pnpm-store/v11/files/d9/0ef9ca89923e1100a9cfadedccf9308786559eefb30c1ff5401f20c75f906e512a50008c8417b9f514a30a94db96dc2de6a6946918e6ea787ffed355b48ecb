"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.stringToHash = stringToHash;
exports.useStack = useStack;
exports.useLimit = useLimit;
const tslib_1 = require("tslib");
const p_limit_1 = tslib_1.__importDefault(require("p-limit"));
/**
 * Converts a string to 32bit integer
 */
function stringToHash(str) {
    let hash = 0;
    if (str.length === 0) {
        return hash;
    }
    let char;
    for (let i = 0; i < str.length; i++) {
        char = str.charCodeAt(i);
        // tslint:disable-next-line: no-bitwise
        hash = (hash << 5) - hash + char;
        // tslint:disable-next-line: no-bitwise
        hash = hash & hash;
    }
    return hash;
}
function useStack(...fns) {
    return (input) => {
        function createNext(i) {
            if (i >= fns.length) {
                return () => { };
            }
            return function next() {
                fns[i](input, createNext(i + 1));
            };
        }
        fns[0](input, createNext(1));
    };
}
function useLimit(concurrency) {
    return (0, p_limit_1.default)(concurrency);
}
