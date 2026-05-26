# sync-fetch
Synchronous wrapper around the Fetch API. Uses [`node-fetch`](https://github.com/bitinn/node-fetch) under the hood, and for some input-parsing code and test cases too.

[![npm](https://img.shields.io/npm/v/sync-fetch?style=flat-square)](https://npmjs.com/package/sync-fetch)
[![npm monthly downloads](https://img.shields.io/npm/dm/sync-fetch?style=flat-square)](https://npm-stat.com/charts.html?package=sync-fetch)

## Install

    npm install sync-fetch

In the browser, a browserify bundle can be loaded from CDNs like unpkg.com.

```html
<script src="https://unpkg.com/sync-fetch"></script>
<script src="https://unpkg.com/sync-fetch@VERSION"></script>
```

## Use

```js
const fetch = require('sync-fetch')

const metadata = fetch('https://doi.org/10.7717/peerj-cs.214', {
  headers: {
    Accept: 'application/vnd.citationstyles.csl+json'
  }
}).json()
// arrayBuffer(), blob(), buffer(), json(), and text() supported
```

## Limitations

### Node.js

  - Does not support `Stream` or `Blob` as input body since they cannot be read or serialized synchronously
  - Does not support `FormData` as input body yet as it has no built-in method to be serialized
  - Does not support the non-spec `agent` option as its value cannot be serialized
  - Does not support non-standard `textConverted()` method on `SyncResponse` and `SyncRequest`

### Browser

  - Does not support most options, since `XMLHttpRequest` is pretty limited. Supported are:
    - `method`
    - `body`
    - `headers`
    - `credentials` (but not `omit`)
    - (Non-spec) `timeout`
  - The non-standard `buffer()` and `textConverted()` methods are not supported
  - CORS limitations apply, of course (note they may be stricter for synchronous requests)
