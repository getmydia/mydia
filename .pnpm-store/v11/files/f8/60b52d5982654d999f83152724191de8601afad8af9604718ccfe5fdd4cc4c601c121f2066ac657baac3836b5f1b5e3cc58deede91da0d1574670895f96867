const util = require('util')
const { Body, checkBody, parseBody, createStream, _state } = require('./body.js')
const { SyncHeaders } = require('./headers.js')

class SyncRequest {
  constructor (resource, init = {}) {
    const nodeFetchOptions = Object.assign(resource instanceof SyncRequest ? { ...resource[_state] } : {}, init)
    const buffer = nodeFetchOptions.body ? parseBody(nodeFetchOptions.body) : null

    if (resource instanceof SyncRequest) {
      const request = serializeRequest(resource)
      resource = request[0]
      init = Object.assign(request[1], init)
    }

    const request = new Request(resource, init)

    Object.defineProperty(this, _state, {
      value: {
        body: buffer,
        bodyStream: buffer ? createStream(buffer) : null,
        bodyUsed: false,
        cache: request.cache,
        credentials: request.credentials,
        destination: request.destination,
        headers: new SyncHeaders(request.headers),
        integrity: request.integrity,
        keepalive: request.keepalive,
        method: request.method,
        mode: request.mode,
        redirect: request.redirect,
        referrer: request.referrer,
        referrerPolicy: request.referrerPolicy,
        signal: request.signal,
        url: request.url,

        // node-fetch
        follow: nodeFetchOptions.follow,
        timeout: nodeFetchOptions.timeout,
        compress: nodeFetchOptions.compress,
        size: nodeFetchOptions.size,
        agent: nodeFetchOptions.agent
      },
      enumerable: false
    })
  }

  get [Symbol.toStringTag] () {
    return 'Request'
  }

  get cache () {
    return this[_state].cache
  }

  get counter () {
    return 0
  }

  get credentials () {
    return this[_state].credentials
  }

  get destination () {
    return this[_state].destination
  }

  get headers () {
    return this[_state].headers
  }

  get integrity () {
    return this[_state].integrity
  }

  get method () {
    return this[_state].method
  }

  get mode () {
    return this[_state].mode
  }

  get priority () {
    return this[_state].priority
  }

  get redirect () {
    return this[_state].redirect
  }

  get referrer () {
    return this[_state].referrer
  }

  get referrerPolicy () {
    return this[_state].referrerPolicy
  }

  get signal () {
    return this[_state].signal
  }

  get url () {
    return this[_state].url
  }

  // node-fetch properties
  get follow () {
    return this[_state].follow
  }

  get timeout () {
    return this[_state].timeout
  }

  get compress () {
    return this[_state].compress
  }

  get size () {
    return this[_state].size
  }

  get agent () {
    return this[_state].agent
  }

  clone () {
    checkBody(this)
    return new SyncRequest(this.url, this[_state])
  }

  [util.inspect.custom] (depth, options) {
    if (options.depth === null) {
      options.depth = 2
    }

    options.colors ??= true

    const properties = {
      ...serializeRequest(this)[1],
      agent: this.agent,
      signal: this.signal,
      url: this.url
    }

    return `Response ${util.formatWithOptions(options, properties)}`
  }
}

Body.mixin(SyncRequest.prototype)
Object.defineProperties(SyncRequest.prototype, {
  cache: { enumerable: true },
  credentials: { enumerable: true },
  destination: { enumerable: true },
  headers: { enumerable: true },
  integrity: { enumerable: true },
  method: { enumerable: true },
  mode: { enumerable: true },
  priority: { enumerable: true },
  redirect: { enumerable: true },
  referrer: { enumerable: true },
  referrerPolicy: { enumerable: true },
  signal: { enumerable: true },
  url: { enumerable: true },
  clone: { enumerable: true }
})

function serializeRequest (request) {
  // TODO credentials

  return [
    request.url,
    {
      body: request[_state].body ? request[_state].body.toString('base64') : undefined,

      cache: request.cache,
      credentials: request.credentials,
      destination: request.destination,
      headers: Array.from(request.headers),
      integrity: request.integrity,
      keepalive: request.keepalive,
      method: request.method,
      mode: request.mode,
      redirect: request.redirect,
      referrer: request.referrer,
      referrerPolicy: request.referrerPolicy,
      // signal: request.signal,

      // node-fetch props
      follow: request.follow,
      timeout: request.timeout,
      compress: request.compress,
      size: request.size
      // agent: request.agent
    }
  ]
}

module.exports = { SyncRequest, serializeRequest }
