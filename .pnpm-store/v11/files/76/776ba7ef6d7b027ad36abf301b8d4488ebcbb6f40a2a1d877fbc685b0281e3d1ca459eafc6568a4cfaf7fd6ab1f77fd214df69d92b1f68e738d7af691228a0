import { detect } from 'chardet';
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import iconv from 'iconv-lite';
import { CreateFileError, LaunchEditorError, ReadFileError, RemoveFileError, } from "./errors.js";
import { parseEditorCommand } from "./parse-editor-command.js";
export { CreateFileError, LaunchEditorError, ReadFileError, RemoveFileError };
export function edit(text = '', fileOptions) {
    return new ExternalEditor(text, fileOptions).run();
}
export const editAsync = (text, callbackOrOptions, fileOptions) => {
    const callback = typeof callbackOrOptions === 'function' ? callbackOrOptions : undefined;
    const options = typeof callbackOrOptions === 'function' ? fileOptions : callbackOrOptions;
    return new ExternalEditor(text, options).runAsync(callback);
};
function sanitizeAffix(affix) {
    if (!affix)
        return '';
    return affix.replace(/[^a-zA-Z0-9_.-]/g, '_');
}
export class ExternalEditor {
    editor;
    lastExitStatus = 0;
    text = '';
    tempFile = '';
    fileOptions = {};
    constructor(text = '', fileOptions = {}) {
        this.text = text;
        this.fileOptions = fileOptions;
        this.editor = parseEditorCommand(process.env['VISUAL'] ??
            process.env['EDITOR'] ??
            (process.platform.startsWith('win') ? 'notepad' : 'vim'));
    }
    run() {
        this.createTempFile();
        try {
            try {
                const editorProcess = spawnSync(this.editor.bin, this.editor.args.concat([this.tempFile]), { stdio: 'inherit' });
                this.lastExitStatus = editorProcess.status ?? 0;
            }
            catch (launchError) {
                throw new LaunchEditorError(launchError);
            }
            this.readTemporaryFile();
            return this.text;
        }
        finally {
            this.cleanup();
        }
    }
    runAsync(callback) {
        this.createTempFile();
        const promise = new Promise((resolve, reject) => {
            try {
                const editorProcess = spawn(this.editor.bin, this.editor.args.concat([this.tempFile]), { stdio: 'inherit' });
                editorProcess.on('exit', (code) => {
                    this.lastExitStatus = code;
                    resolve();
                });
            }
            catch (launchError) {
                reject(new LaunchEditorError(launchError));
            }
        })
            .then(() => {
            this.readTemporaryFile();
            return this.text;
        })
            .finally(() => {
            this.cleanup();
        });
        if (callback) {
            promise.then((text) => callback(undefined, text), (err) => callback(err instanceof Error ? err : new Error(String(err)), undefined));
        }
        return promise;
    }
    cleanup() {
        if (!this.tempFile)
            return;
        try {
            unlinkSync(this.tempFile);
            this.tempFile = '';
        }
        catch (removeFileError) {
            throw new RemoveFileError(removeFileError);
        }
    }
    createTempFile() {
        try {
            const baseDir = this.fileOptions.dir ?? os.tmpdir();
            const id = randomUUID();
            const prefix = sanitizeAffix(this.fileOptions.prefix);
            const postfix = sanitizeAffix(this.fileOptions.postfix);
            const filename = `${prefix}${id}${postfix}`;
            const candidate = path.resolve(baseDir, filename);
            const baseResolved = path.resolve(baseDir) + path.sep;
            if (!candidate.startsWith(baseResolved)) {
                throw new Error('Resolved temporary file escaped the base directory');
            }
            this.tempFile = candidate;
            const opt = { encoding: 'utf8', flag: 'wx' };
            if (Object.prototype.hasOwnProperty.call(this.fileOptions, 'mode')) {
                opt.mode = this.fileOptions.mode;
            }
            writeFileSync(this.tempFile, this.text, opt);
        }
        catch (createFileError) {
            throw new CreateFileError(createFileError);
        }
    }
    readTemporaryFile() {
        try {
            const tempFileBuffer = readFileSync(this.tempFile);
            if (tempFileBuffer.length === 0) {
                this.text = '';
            }
            else {
                let encoding = detect(tempFileBuffer) ?? 'utf8';
                if (!iconv.encodingExists(encoding)) {
                    // Probably a bad idea, but will at least prevent crashing
                    encoding = 'utf8';
                }
                this.text = iconv.decode(tempFileBuffer, encoding);
            }
        }
        catch (readFileError) {
            throw new ReadFileError(readFileError);
        }
    }
}
