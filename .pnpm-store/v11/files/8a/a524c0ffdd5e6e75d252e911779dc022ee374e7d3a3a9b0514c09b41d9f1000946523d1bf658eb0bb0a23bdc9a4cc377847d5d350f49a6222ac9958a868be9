/**
Create an AbortSignal that aborts after a delay.

@param timeout - The milliseconds to wait.

@example
```
import timeoutSignal from 'timeout-signal';

try {
	const response = await fetch('https://www.google.com', {signal: timeoutSignal(5000)});
	// Handle response
} catch (error) {
	if (signal.aborted) {
		// Handle abortion
	}
}
```
*/
export default function timeoutSignal(timeout: number): AbortSignal;
