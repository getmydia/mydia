import { CreateFileError, LaunchEditorError, ReadFileError, RemoveFileError } from './errors.ts';
import { type EditorParams } from './parse-editor-command.ts';
type StringCallback = (err: Error | undefined, result: string | undefined) => void;
export type FileOptions = {
    prefix?: string;
    postfix?: string;
    mode?: number;
    template?: string;
    dir?: string;
};
/** @deprecated Use FileOptions */
export type IFileOptions = FileOptions;
export { CreateFileError, LaunchEditorError, ReadFileError, RemoveFileError };
export declare function edit(text?: string, fileOptions?: FileOptions): string;
type EditAsync = {
    /** @deprecated Use editAsync(text, options) returning a Promise instead */
    (text: string, callback: StringCallback, fileOptions?: FileOptions): Promise<string>;
    (text?: string, fileOptions?: FileOptions): Promise<string>;
};
export declare const editAsync: EditAsync;
export declare class ExternalEditor {
    editor: EditorParams;
    lastExitStatus: number;
    private text;
    private tempFile;
    private fileOptions;
    constructor(text?: string, fileOptions?: FileOptions);
    run(): string;
    runAsync(callback?: StringCallback): Promise<string>;
    private cleanup;
    private createTempFile;
    private readTemporaryFile;
}
