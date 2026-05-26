const exec = require('child_process').execFileSync
const path = require('path')

const { SyncHeaders } = require('./src/headers.js')
const { FetchError, deserializeError } = require('./src/error.js')
const { SyncRequest, serializeRequest } = require('./src/request.js')
const { SyncResponse, deserializeResponse } = require('./src/response.js')

function syncFetch (resource, init) {
  const request = serializeRequest(new syncFetch.Request(resource, init))

  const [status, ...response] = JSON.parse(sendMessage(request))
  if (status === 0) {
    return deserializeResponse(...response)
  } else {
    throw deserializeError(...response[0])
  }
}

function sendMessage (message) {
  return exec(process.execPath, [path.join(__dirname, 'worker.js')], {
    windowsHide: true,
    maxBuffer: Infinity,
    input: JSON.stringify(message),
    shell: false
  }).toString()
}

syncFetch.Headers = SyncHeaders
syncFetch.FetchError = FetchError
syncFetch.Request = SyncRequest
syncFetch.Response = SyncResponse
module.exports = syncFetch
