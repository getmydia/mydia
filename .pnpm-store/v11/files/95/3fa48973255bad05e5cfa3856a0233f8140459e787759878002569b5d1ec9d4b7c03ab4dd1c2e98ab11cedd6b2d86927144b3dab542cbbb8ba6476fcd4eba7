export function isListrError(err) {
    return err.name === 'ListrError' && Array.isArray(err.errors) && err.errors.length > 0;
}
export function cliError(err, exitOnError = true) {
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
