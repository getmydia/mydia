import { asArray, debugTimerEnd, debugTimerStart } from '@graphql-tools/utils';
export function normalizePointers(unnormalizedPointerOrPointers) {
    debugTimerStart('@graphql-tools/load: normalizePointers');
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
    for (const rawPointer of asArray(unnormalizedPointerOrPointers)) {
        debugTimerStart(`@graphql-tools/load: normalizePointers ${rawPointer}`);
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
        debugTimerEnd(`@graphql-tools/load: normalizePointers ${rawPointer}`);
    }
    debugTimerEnd('@graphql-tools/load: normalizePointers');
    return { ignore, pointerOptionMap };
}
