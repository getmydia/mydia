'use strict';

function extendedTypeof(val) {
  if (val === null) {
    return "null";
  }
  if (Array.isArray(val)) {
    return "array";
  }
  return typeof val;
}
function isObject(val) {
  return extendedTypeof(val) === "object";
}
function isAsyncIterable(val) {
  return typeof Object(val)[Symbol.asyncIterator] === "function";
}
function isAsyncGenerator(val) {
  return isObject(val) && typeof Object(val)[Symbol.asyncIterator] === "function" && typeof val.return === "function";
}
function areGraphQLFormattedErrors(obj) {
  return Array.isArray(obj) && // must be at least one error
  obj.length > 0 && // error has at least a message
  obj.every((ob) => "message" in ob);
}
function limitCloseReason(reason, whenTooLong) {
  return reason.length < 124 ? reason : whenTooLong;
}

const GRAPHQL_TRANSPORT_WS_PROTOCOL = "graphql-transport-ws";
const DEPRECATED_GRAPHQL_WS_PROTOCOL = "graphql-ws";
var CloseCode = /* @__PURE__ */ ((CloseCode2) => {
  CloseCode2[CloseCode2["InternalServerError"] = 4500] = "InternalServerError";
  CloseCode2[CloseCode2["InternalClientError"] = 4005] = "InternalClientError";
  CloseCode2[CloseCode2["BadRequest"] = 4400] = "BadRequest";
  CloseCode2[CloseCode2["BadResponse"] = 4004] = "BadResponse";
  CloseCode2[CloseCode2["Unauthorized"] = 4401] = "Unauthorized";
  CloseCode2[CloseCode2["Forbidden"] = 4403] = "Forbidden";
  CloseCode2[CloseCode2["SubprotocolNotAcceptable"] = 4406] = "SubprotocolNotAcceptable";
  CloseCode2[CloseCode2["ConnectionInitialisationTimeout"] = 4408] = "ConnectionInitialisationTimeout";
  CloseCode2[CloseCode2["ConnectionAcknowledgementTimeout"] = 4504] = "ConnectionAcknowledgementTimeout";
  CloseCode2[CloseCode2["SubscriberAlreadyExists"] = 4409] = "SubscriberAlreadyExists";
  CloseCode2[CloseCode2["TooManyInitialisationRequests"] = 4429] = "TooManyInitialisationRequests";
  return CloseCode2;
})(CloseCode || {});
var MessageType = /* @__PURE__ */ ((MessageType2) => {
  MessageType2["ConnectionInit"] = "connection_init";
  MessageType2["ConnectionAck"] = "connection_ack";
  MessageType2["Ping"] = "ping";
  MessageType2["Pong"] = "pong";
  MessageType2["Subscribe"] = "subscribe";
  MessageType2["Next"] = "next";
  MessageType2["Error"] = "error";
  MessageType2["Complete"] = "complete";
  return MessageType2;
})(MessageType || {});
function validateMessage(val) {
  if (!isObject(val)) {
    throw new Error(
      `Message is expected to be an object, but got ${extendedTypeof(val)}`
    );
  }
  if (!val.type) {
    throw new Error(`Message is missing the 'type' property`);
  }
  if (typeof val.type !== "string") {
    throw new Error(
      `Message is expects the 'type' property to be a string, but got ${extendedTypeof(
        val.type
      )}`
    );
  }
  switch (val.type) {
    case "connection_init" /* ConnectionInit */:
    case "connection_ack" /* ConnectionAck */:
    case "ping" /* Ping */:
    case "pong" /* Pong */: {
      if (val.payload != null && !isObject(val.payload)) {
        throw new Error(
          `"${val.type}" message expects the 'payload' property to be an object or nullish or missing, but got "${val.payload}"`
        );
      }
      break;
    }
    case "subscribe" /* Subscribe */: {
      if (typeof val.id !== "string") {
        throw new Error(
          `"${val.type}" message expects the 'id' property to be a string, but got ${extendedTypeof(
            val.id
          )}`
        );
      }
      if (!val.id) {
        throw new Error(
          `"${val.type}" message requires a non-empty 'id' property`
        );
      }
      if (!isObject(val.payload)) {
        throw new Error(
          `"${val.type}" message expects the 'payload' property to be an object, but got ${extendedTypeof(
            val.payload
          )}`
        );
      }
      if (typeof val.payload.query !== "string") {
        throw new Error(
          `"${val.type}" message payload expects the 'query' property to be a string, but got ${extendedTypeof(
            val.payload.query
          )}`
        );
      }
      if (val.payload.variables != null && !isObject(val.payload.variables)) {
        throw new Error(
          `"${val.type}" message payload expects the 'variables' property to be a an object or nullish or missing, but got ${extendedTypeof(
            val.payload.variables
          )}`
        );
      }
      if (val.payload.operationName != null && extendedTypeof(val.payload.operationName) !== "string") {
        throw new Error(
          `"${val.type}" message payload expects the 'operationName' property to be a string or nullish or missing, but got ${extendedTypeof(
            val.payload.operationName
          )}`
        );
      }
      if (val.payload.extensions != null && !isObject(val.payload.extensions)) {
        throw new Error(
          `"${val.type}" message payload expects the 'extensions' property to be a an object or nullish or missing, but got ${extendedTypeof(
            val.payload.extensions
          )}`
        );
      }
      break;
    }
    case "next" /* Next */: {
      if (typeof val.id !== "string") {
        throw new Error(
          `"${val.type}" message expects the 'id' property to be a string, but got ${extendedTypeof(
            val.id
          )}`
        );
      }
      if (!val.id) {
        throw new Error(
          `"${val.type}" message requires a non-empty 'id' property`
        );
      }
      if (!isObject(val.payload)) {
        throw new Error(
          `"${val.type}" message expects the 'payload' property to be an object, but got ${extendedTypeof(
            val.payload
          )}`
        );
      }
      break;
    }
    case "error" /* Error */: {
      if (typeof val.id !== "string") {
        throw new Error(
          `"${val.type}" message expects the 'id' property to be a string, but got ${extendedTypeof(
            val.id
          )}`
        );
      }
      if (!val.id) {
        throw new Error(
          `"${val.type}" message requires a non-empty 'id' property`
        );
      }
      if (!areGraphQLFormattedErrors(val.payload)) {
        throw new Error(
          `"${val.type}" message expects the 'payload' property to be an array of GraphQL errors, but got ${JSON.stringify(
            val.payload
          )}`
        );
      }
      break;
    }
    case "complete" /* Complete */: {
      if (typeof val.id !== "string") {
        throw new Error(
          `"${val.type}" message expects the 'id' property to be a string, but got ${extendedTypeof(
            val.id
          )}`
        );
      }
      if (!val.id) {
        throw new Error(
          `"${val.type}" message requires a non-empty 'id' property`
        );
      }
      break;
    }
    default:
      throw new Error(`Invalid message 'type' property "${val.type}"`);
  }
  return val;
}
function parseMessage(data, reviver) {
  return validateMessage(
    typeof data === "string" ? JSON.parse(data, reviver) : data
  );
}
function stringifyMessage(msg, replacer) {
  validateMessage(msg);
  return JSON.stringify(msg, replacer);
}

exports.CloseCode = CloseCode;
exports.DEPRECATED_GRAPHQL_WS_PROTOCOL = DEPRECATED_GRAPHQL_WS_PROTOCOL;
exports.GRAPHQL_TRANSPORT_WS_PROTOCOL = GRAPHQL_TRANSPORT_WS_PROTOCOL;
exports.MessageType = MessageType;
exports.isAsyncGenerator = isAsyncGenerator;
exports.isAsyncIterable = isAsyncIterable;
exports.isObject = isObject;
exports.limitCloseReason = limitCloseReason;
exports.parseMessage = parseMessage;
exports.stringifyMessage = stringifyMessage;
exports.validateMessage = validateMessage;
