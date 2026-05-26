class FetchError extends Error {
  constructor (message, type, systemError) {
    super(message)
    this.type = type
    if (systemError) {
      this.code = this.errno = systemError.code
    }
  }

  get name () {
    return 'FetchError'
  }

  get [Symbol.toStringTag] () {
    return 'FetchError'
  }
}

const errors = {
  TypeError
}

function deserializeError (name, init) {
  if (name in errors) {
    return new errors[name](...init)
  } else {
    return new FetchError(...init)
  }
}

module.exports = { FetchError, deserializeError }
