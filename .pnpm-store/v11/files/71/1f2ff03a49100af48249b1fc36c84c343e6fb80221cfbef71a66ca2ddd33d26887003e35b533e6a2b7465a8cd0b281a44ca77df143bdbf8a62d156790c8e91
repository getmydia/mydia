const http = require('node:http')

const _state = Symbol('headers map')

function prepareHeaderName (name) {
  name = name.toLowerCase()
  http.validateHeaderName(name)

  return name
}

function prepareHeader (name, value) {
  name = prepareHeaderName(name)
  value = (value + '').trim()
  http.validateHeaderValue(name, value)

  return [name, value]
}

class SyncHeaders {
  constructor (headers) {
    this[_state] = {}

    if (headers instanceof SyncHeaders) {
      this[_state] = headers.raw()
    } else if (headers != null && headers[Symbol.iterator] != null) {
      if (typeof headers[Symbol.iterator] !== 'function') {
        throw new TypeError('Header pairs must be iterable')
      }

      for (const header of headers) {
        if (header == null || typeof header[Symbol.iterator] !== 'function') {
          throw new TypeError('Header pairs must be iterable')
        }

        if (typeof header === 'string') {
          throw new TypeError('Each header pair must be an iterable object')
        }

        const pair = Array.from(header)

        if (pair.length !== 2) {
          throw new TypeError('Each header pair must be a name/value tuple')
        }

        const [name, value] = pair

        this.append(name, value)
      }
    } else if (typeof headers === 'object') {
      for (const name of Object.keys(headers)) {
        this.set(name, headers[name])
      }
    } else if (headers !== undefined) {
      throw new TypeError('The provided value is not of type \'(sequence<sequence<ByteString>> or record<ByteString, ByteString>)\'')
    }
  }

  append (name, value) {
    [name, value] = prepareHeader(name, value)

    if (this[_state][name]) {
      this[_state][name].push(value)
    } else {
      this[_state][name] = [value]
    }
  }

  delete (name) {
    name = prepareHeaderName(name)
    delete this[_state][name]
  }

  entries () {
    return this.keys().map(key => [key, this.get(key)])
  }

  forEach (callback, thisArg) {
    for (const [name, value] of this.entries()) {
      callback.call(thisArg ?? null, value, name, this)
    }
  }

  get (name) {
    name = prepareHeaderName(name)
    if (this.has(name)) {
      return this[_state][name].join(', ')
    }
    return null
  }

  getSetCookie () {
    const name = 'set-cookie'
    if (this.has(name)) {
      return this[_state][name].slice()
    }
    return []
  }

  has (name) {
    name = prepareHeaderName(name)
    return Object.prototype.hasOwnProperty.call(this[_state], name)
  }

  keys () {
    return Object.keys(this[_state]).sort()
  }

  set (name, value) {
    [name, value] = prepareHeader(name, value)
    this[_state][name] = [value]
  }

  raw () {
    const headers = {}
    for (const name of this.keys()) {
      headers[name] = this[_state][name].slice()
    }
    return headers
  }

  values () {
    return this.keys().map(key => this.get(key))
  }

  * [Symbol.iterator] () {
    for (const entry of this.entries()) {
      yield entry
    }
  }

  get [Symbol.toStringTag] () {
    return 'Headers'
  }
}

Object.defineProperties(SyncHeaders.prototype, {
  append: { enumerable: true },
  delete: { enumerable: true },
  entries: { enumerable: true },
  forEach: { enumerable: true },
  get: { enumerable: true },
  getSetCookie: { enumerable: true },
  has: { enumerable: true },
  keys: { enumerable: true },
  set: { enumerable: true },
  values: { enumerable: true }
})

function initializeHeaders (rawHeaders) {
  const headers = new SyncHeaders()
  headers[_state] = rawHeaders
  return headers
}

module.exports = { SyncHeaders, initializeHeaders }
