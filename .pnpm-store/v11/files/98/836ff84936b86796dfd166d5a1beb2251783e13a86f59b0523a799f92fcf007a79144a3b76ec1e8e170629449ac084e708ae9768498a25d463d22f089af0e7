import { editAsync } from '@inquirer/external-editor';
import { createPrompt, useEffect, useState, useKeypress, usePrefix, isEnterKey, makeTheme, } from '@inquirer/core';
const editorTheme = {
    validationFailureMode: 'keep',
    style: {
        loadingMessage: () => 'Validating...',
        waitingMessage: (enterKey) => `Press ${enterKey} to launch your preferred editor.`,
    },
};
export default createPrompt((config, done) => {
    const { waitForUserInput = true, file: { postfix = config.postfix ?? '.txt', ...fileProps } = {}, validate = () => true, } = config;
    const theme = makeTheme(editorTheme, config.theme);
    const [status, setStatus] = useState('idle');
    const [value = '', setValue] = useState(config.default);
    const [errorMsg, setError] = useState();
    const prefix = usePrefix({ status, theme });
    async function startEditor(rl) {
        rl.pause();
        try {
            const answer = await editAsync(value, { postfix, ...fileProps });
            rl.resume();
            setStatus('loading');
            const isValid = await validate(answer);
            if (isValid === true) {
                setError(undefined);
                setStatus('done');
                done(answer);
            }
            else {
                if (theme.validationFailureMode === 'clear') {
                    setValue(config.default);
                }
                else {
                    setValue(answer);
                }
                setError(isValid || 'You must provide a valid value');
                setStatus('idle');
            }
        }
        catch (error) {
            rl.resume();
            setError(String(error));
        }
    }
    useEffect((rl) => {
        if (!waitForUserInput) {
            void startEditor(rl);
        }
    }, []);
    useKeypress((key, rl) => {
        // Ignore keypress while our prompt is doing other processing.
        if (status !== 'idle') {
            return;
        }
        if (isEnterKey(key)) {
            void startEditor(rl);
        }
    });
    const message = theme.style.message(config.message, status);
    let helpTip = '';
    if (status === 'loading') {
        helpTip = theme.style.help(theme.style.loadingMessage());
    }
    else if (status === 'idle') {
        const enterKey = theme.style.key('enter');
        helpTip = theme.style.help(theme.style.waitingMessage(enterKey));
    }
    let error = '';
    if (errorMsg) {
        error = theme.style.error(errorMsg);
    }
    return [[prefix, message, helpTip].filter(Boolean).join(' '), error];
});
