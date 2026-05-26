/**
 * Memory safe ponyfill of `AbortSignal.any`. In Node environments, the native
 * `AbortSignal.any` seems to be leaky and can lead to subtle memory leaks over
 * a larger period of time.
 *
 * This ponyfill is a custom implementation that makes sure AbortSignals get properly
 * GC-ed as well as aborted.
 */
declare function abortSignalAny(signals: AbortSignal[]): AbortSignal | undefined;

export { abortSignalAny };
