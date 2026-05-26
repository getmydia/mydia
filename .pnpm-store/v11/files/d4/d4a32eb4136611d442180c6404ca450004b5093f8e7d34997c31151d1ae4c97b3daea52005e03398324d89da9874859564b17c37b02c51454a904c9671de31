# timeout-signal

> Create an AbortSignal that aborts after a delay

## Install

```sh
npm install timeout-signal
```

## Usage

```js
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

## API

### timeoutSignal(timeout)

#### timeout

Type: `integer`

The milliseconds to wait.
