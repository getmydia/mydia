# ts-log

[![CI](https://github.com/kallaspriit/ts-log/actions/workflows/ci.yml/badge.svg)](https://github.com/kallaspriit/ts-log/actions/workflows/ci.yml)
[![Downloads](https://img.shields.io/npm/dm/ts-log.svg)](http://npm-stat.com/charts.html?package=ts-log)
[![Version](https://img.shields.io/npm/v/ts-log.svg)](http://npm.im/ts-log)
[![License](https://img.shields.io/npm/l/ts-log.svg)](http://opensource.org/licenses/MIT)
[![StackGrit Score](https://img.shields.io/endpoint?url=https%3A%2F%2Ffleet-trout-946.convex.site%2Fapi%2Fbadge%2Fab080bce-08cf-4c0a-9ffa-c165470ad08d)](https://app.stackgrit.com/shared/b16e2501260e476597552a610a0b5542/reports/latest)

A zero-dependency TypeScript logger interface. Let library consumers choose their own logger — or stay silent by default.

## Installation

```
npm install ts-log
```

## Usage

Accept a `Logger` in your library's constructor, defaulting to `dummyLogger` (which does nothing):

```typescript
import { Logger, dummyLogger } from "ts-log";

class MyService {
  constructor(private readonly logger: Logger = dummyLogger) {}

  doWork() {
    this.logger.info("work started");
    // ...
    this.logger.debug("details", { foo: "bar" });
  }
}
```

Consumers can then pass in any compatible logger — or leave the default:

```typescript
// silent by default
const service = new MyService();

// or use the built-in console
const service = new MyService(console);

// or use pino, bunyan, winston, etc.
import pino from "pino";
const service = new MyService(pino());
```

## Logger Interface

The interface mirrors `console` — five methods, each accepting a message and optional parameters:

```typescript
interface Logger {
  trace(message?: any, ...optionalParams: any[]): void;
  debug(message?: any, ...optionalParams: any[]): void;
  info(message?: any, ...optionalParams: any[]): void;
  warn(message?: any, ...optionalParams: any[]): void;
  error(message?: any, ...optionalParams: any[]): void;
}
```

Any object matching this shape works — no adapters needed. This includes `console`, [pino](https://github.com/pinojs/pino), [bunyan](https://github.com/trentm/node-bunyan), [winston](https://github.com/winstonjs/winston), and most other Node.js loggers.

## Custom Logger

You can implement the interface directly for custom behavior:

```typescript
import fs from "node:fs";
import { Logger } from "ts-log";

class FileLogger implements Logger {
  private readonly fd: number;

  constructor(filename: string) {
    this.fd = fs.openSync(filename, "a");
  }

  trace(message?: any, ...params: any[]) {
    this.write("TRACE", message, params);
  }
  debug(message?: any, ...params: any[]) {
    this.write("DEBUG", message, params);
  }
  info(message?: any, ...params: any[]) {
    this.write("INFO", message, params);
  }
  warn(message?: any, ...params: any[]) {
    this.write("WARN", message, params);
  }
  error(message?: any, ...params: any[]) {
    this.write("ERROR", message, params);
  }

  private write(level: string, message: any, params: any[]) {
    fs.writeSync(this.fd, `${new Date().toISOString()} ${level} ${message} ${JSON.stringify(params)}\n`);
  }
}
```

## v3 Migration

v3 is a tooling modernization — the `Logger` interface and `dummyLogger` API are unchanged.

- Dual CJS/ESM package (via `exports` field).
- `"type": "module"` added to package.json.
- Minimum Node.js version is 20.
- Build output moved from `build/src/` to `dist/`.

## License

MIT
