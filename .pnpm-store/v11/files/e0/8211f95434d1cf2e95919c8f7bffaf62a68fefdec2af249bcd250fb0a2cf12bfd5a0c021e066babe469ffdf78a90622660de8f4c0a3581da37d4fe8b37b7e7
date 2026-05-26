export default function timeoutSignal(timeout) {
	if (!Number.isInteger(timeout)) {
		throw new TypeError('Expected an integer');
	}

	const controller = new AbortController();

	const timeoutId = setTimeout(() => {
		controller.abort();
	}, timeout);

	// Allow Node.js processes to exit early if only the timeout is running
	timeoutId?.unref?.();

	return controller.signal;
}
