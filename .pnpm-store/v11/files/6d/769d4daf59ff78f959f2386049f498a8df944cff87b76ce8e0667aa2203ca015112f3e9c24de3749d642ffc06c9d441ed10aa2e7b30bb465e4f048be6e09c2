const isNode = !globalThis.Bun && globalThis.process?.release?.name === "node";
const anySignalRegistry = isNode ? new FinalizationRegistry((cb) => cb()) : null;
const controllerInSignalSy = Symbol("CONTROLLER_IN_SIGNAL");
function abortSignalAny(signals) {
  if (signals.length === 0) {
    return void 0;
  }
  if (signals.length === 1) {
    return signals[0];
  }
  if (!isNode) {
    return AbortSignal.any(signals);
  }
  for (const signal of signals) {
    if (signal.aborted) {
      return signal;
    }
  }
  const ctrl = new AbortController();
  const ctrlRef = new WeakRef(ctrl);
  const eventListenerPairs = [];
  let retainedSignalsCount = signals.length;
  for (const signal of signals) {
    let abort2 = function() {
      ctrlRef.deref()?.abort(signalRef.deref()?.reason);
    };
    const signalRef = new WeakRef(signal);
    signal.addEventListener("abort", abort2);
    eventListenerPairs.push([signalRef, abort2]);
    anySignalRegistry.register(
      signal,
      () => (
        // dispose when all of the signals have been GCed
        !--retainedSignalsCount && dispose()
      ),
      signal
    );
  }
  function dispose() {
    for (const [signalRef, abort2] of eventListenerPairs) {
      const signal = signalRef.deref();
      if (signal) {
        signal.removeEventListener("abort", abort2);
        anySignalRegistry.unregister(signal);
      }
      const ctrl2 = ctrlRef.deref();
      if (ctrl2) {
        anySignalRegistry.unregister(ctrl2.signal);
        delete ctrl2.signal[controllerInSignalSy];
      }
    }
  }
  ctrl.signal.addEventListener("abort", dispose);
  anySignalRegistry.register(ctrl.signal, dispose, ctrl.signal);
  ctrl.signal[controllerInSignalSy] = ctrl;
  return ctrl.signal;
}

export { abortSignalAny };
