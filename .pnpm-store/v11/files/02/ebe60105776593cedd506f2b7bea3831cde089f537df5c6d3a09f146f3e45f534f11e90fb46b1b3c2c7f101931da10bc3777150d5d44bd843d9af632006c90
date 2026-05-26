type CompositeError = Error;
type ListrError = Error & {
    errors: CompositeError[];
};
export declare function isListrError(err: Error & {
    name?: unknown;
    errors?: unknown;
}): err is ListrError;
export declare function cliError(err: any, exitOnError?: boolean): void;
export {};
