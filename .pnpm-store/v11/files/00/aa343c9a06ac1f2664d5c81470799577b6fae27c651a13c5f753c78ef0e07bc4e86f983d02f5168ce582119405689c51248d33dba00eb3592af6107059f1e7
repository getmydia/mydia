import syncFetchImported from 'sync-fetch';
export const defaultSyncFetch = (input, init) => {
    if (typeof input === 'string') {
        delete init?.signal;
    }
    else {
        delete input.signal;
    }
    return syncFetchImported(input, init);
};
