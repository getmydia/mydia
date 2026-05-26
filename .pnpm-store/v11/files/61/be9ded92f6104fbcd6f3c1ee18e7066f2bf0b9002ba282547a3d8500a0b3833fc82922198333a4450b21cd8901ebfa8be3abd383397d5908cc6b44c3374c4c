#!/usr/bin/env node

const chunks = []

process.stdin.resume()
process.stdin.setEncoding('utf8')

process.stdin.on('data', function (chunk) {
  chunks.push(chunk)
})

process.stdin.on('end', function () {
  const [resource, init] = JSON.parse(chunks.join(''))

  import('node-fetch')
    .then(({ default: fetch, Headers, Request }) => {
      init.body = init.body ? Buffer.from(init.body, 'base64') : undefined
      init.headers = new Headers(init.headers)

      if (init.timeout) {
        const signal = timeoutSignal(init.timeout)
        if (init.signal) {
          init.signal = AbortSignal.any([init.signal, signal])
        } else {
          init.signal = signal
        }
      }

      return fetch(new Request(resource, init), {})
    })
    .then(response => response.arrayBuffer()
      .then(buffer => respond(serializeResponse(Buffer.from(buffer).toString('base64'), response)))
      .catch(error => {
        if (error.name === 'AbortError' && init.signal && init.signal.reason === 'timeout') {
          error.type = 'body-timeout'
        }
        return respond(serializeResponse('', response, error))
      })
    )
    .catch(error => {
      if (error.name === 'AbortError' && init.signal && init.signal.reason === 'timeout') {
        error.type = 'request-timeout'
      }
      return respondWithError(error)
    })
})

// Adapted from https://github.com/node-fetch/timeout-signal/blob/main/index.js
function timeoutSignal (timeout) {
  if (!Number.isInteger(timeout)) {
    throw new TypeError('Expected an integer')
  }

  const controller = new AbortController()

  const timeoutId = setTimeout(() => {
    controller.abort('timeout')
  }, timeout)

  if (typeof timeoutId.unref === 'function') {
    timeoutId.unref()
  }

  return controller.signal
}

function serializeResponse (body, response, bodyError) {
  const init = {
    headers: response.headers.raw(),
    status: response.status,
    statusText: response.statusText,
    redirected: response.redirected,
    type: response.type,
    url: response.url
  }

  return [0, body, init, bodyError ? serializeError(bodyError) : null]
}

function serializeError ({ constructor, message, type, code }) {
  return [
    constructor.name,
    [message, type, { code }]
  ]
}

function respond (message) {
  process.stdout.write(JSON.stringify(message))
}

function respondWithError (error) {
  if (error.cause && error.message === 'fetch failed') {
    respondWithError(error.cause)
  } else {
    respond([1, serializeError(error)])
  }
}
