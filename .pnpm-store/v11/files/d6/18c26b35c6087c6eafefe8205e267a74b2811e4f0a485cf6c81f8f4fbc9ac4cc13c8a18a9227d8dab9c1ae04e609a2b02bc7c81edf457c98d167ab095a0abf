"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.isListrError = isListrError;
exports.cliError = cliError;
function isListrError(err) {
    return err.name === 'ListrError' && Array.isArray(err.errors) && err.errors.length > 0;
}
function cliError(err, exitOnError = true) {
    let msg;
    if (err instanceof Error) {
        msg = err;
    }
    else if (typeof err === 'string') {
        msg = err;
    }
    else {
        msg = JSON.stringify(err);
    }
    // eslint-disable-next-line no-console
    console.error(msg);
    if (exitOnError) {
        process.exit(1);
    }
}
