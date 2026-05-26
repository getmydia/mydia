"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.normalizePointers = normalizePointers;
const utils_1 = require("@graphql-tools/utils");
function normalizePointers(unnormalizedPointerOrPointers) {
    (0, utils_1.debugTimerStart)('@graphql-tools/load: normalizePointers');
    const ignore = [];
    const pointerOptionMap = {};
    const handlePointer = (rawPointer, options = {}) => {
        if (rawPointer.startsWith('!')) {
            ignore.push(rawPointer.replace('!', ''));
        }
        else {
            pointerOptionMap[rawPointer] = options;
        }
    };
    for (const rawPointer of (0, utils_1.asArray)(unnormalizedPointerOrPointers)) {
        (0, utils_1.debugTimerStart)(`@graphql-tools/load: normalizePointers ${rawPointer}`);
        if (typeof rawPointer === 'string') {
            handlePointer(rawPointer);
        }
        else if (typeof rawPointer === 'object') {
            for (const [path, options] of Object.entries(rawPointer)) {
                handlePointer(path, options);
            }
        }
        else {
            throw new Error(`Invalid pointer '${rawPointer}'.`);
        }
        (0, utils_1.debugTimerEnd)(`@graphql-tools/load: normalizePointers ${rawPointer}`);
    }
    (0, utils_1.debugTimerEnd)('@graphql-tools/load: normalizePointers');
    return { ignore, pointerOptionMap };
}
