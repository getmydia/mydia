const util = require('util')
const { Body, checkBody, parseBody, createStream, _state } = require('./body.js')
const { deserializeError } = require('./error.js')
const { SyncHeaders, initializeHeaders } = require('./headers.js')

class SyncResponse {
  constructor (body, options = {}) {
    if (typeof options !== 'object') {
      throw new TypeError('expected options to be an object')
    }

    const buffer = parseBody(body)

    Object.defineProperty(this, _state, {
      value: {
        status: options.status ?? 200,
        statusText: options.statusText ?? '',
        headers: new SyncHeaders(options.headers),
        url: '',
        body: buffer,
        bodyStream: body ? createStream(buffer) : null,
        bodyUsed: false
      },
      enumerable: false
    })

    if (body && !this.headers.has('content-type')) {
      const response = new Response(body)
      this.headers.append('content-type', response.headers.get('content-type'))
    }

    // node-fetch compatibility
    if (options.url) {
      this[_state].url = options.url
    }
  }

  get [Symbol.toStringTag] () {
    return 'Response'
  }

  get headers () {
    return this[_state].headers
  }

  get ok () {
    const status = this[_state].status
    return status >= 200 && status < 300
  }

  get redirected () {
    return this[_state].redirected
  }

  get status () {
    return this[_state].status
  }

  get statusText () {
    return this[_state].statusText
  }

  get type () {
    return this[_state].type
  }

  get url () {
    return this[_state].url
  }

  clone () {
    checkBody(this)
    return initializeResponse(
      {
        status: this.status,
        statusText: this.statusText,
        headers: new SyncHeaders(Array.from(this.headers))
      },
      {
        body: Buffer.from(this[_state].body),
        bodyError: this.bodyError,
        redirected: this.redirected,
        type: this.type,
        url: this.url
      }
    )
  }

  [util.inspect.custom] (depth, options) {
    if (options.depth === null) {
      options.depth = 2
    }

    options.colors ??= true

    const properties = {
      status: this.status,
      statusText: this.statusText,
      headers: this.headers,
      body: this.body,
      bodyUsed: this.bodyUsed,
      ok: this.ok,
      redirected: this.redirected,
      type: this.type,
      url: this.url
    }

    return `Response ${util.formatWithOptions(options, properties)}`
  }
}

Body.mixin(SyncResponse.prototype)
Object.defineProperties(SyncResponse.prototype, {
  headers: { enumerable: true },
  ok: { enumerable: true },
  redirected: { enumerable: true },
  status: { enumerable: true },
  statusText: { enumerable: true },
  type: { enumerable: true },
  url: { enumerable: true },
  clone: { enumerable: true }
})

/**
 * @param {object} [options]
 * @param {number} [options.status]
 * @param {string} [options.statusText]
 * @param {Headers|object|array} [options.headers]
 * @param {object} [state]
 * @param {Buffer} [state.body]
 * @param {Error} [state.bodyError]
 * @param {boolean} [state.redirected]
 * @param {string} [state.type]
 * @param {string} [state.url]
 */
function initializeResponse (init, state) {
  const response = new SyncResponse(state.body, init)

  response[_state].bodyError = state.bodyError
  response[_state].redirected = state.redirected
  response[_state].type = state.type
  response[_state].url = state.url

  return response
}

/**
 * @param {string} body
 * @param {object} init
 * @param {array} [bodyError]
 */
function deserializeResponse (body, init, bodyError) {
  const options = {
    ...init,
    headers: initializeHeaders(init.headers)
  }
  const state = {
    ...init,
    body: Buffer.from(body, 'base64'),
    bodyError: bodyError ? deserializeError(...bodyError) : undefined
  }

  return initializeResponse(options, state)
}

module.exports = { SyncResponse, deserializeResponse }
