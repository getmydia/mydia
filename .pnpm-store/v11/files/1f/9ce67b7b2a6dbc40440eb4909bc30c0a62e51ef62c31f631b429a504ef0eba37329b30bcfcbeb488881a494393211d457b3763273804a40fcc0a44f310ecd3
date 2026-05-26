'use strict';

var crossws = require('crossws');
var common = require('../common-DqFHi7oM.cjs');
var server = require('../server-BVbx-kML.cjs');
require('graphql');

function makeHooks(options) {
  const isProd = typeof options.isProd === "boolean" ? options.isProd : process.env.NODE_ENV === "production";
  const server$1 = server.makeServer(options);
  const clients = /* @__PURE__ */ new WeakMap();
  return crossws.defineHooks({
    open(peer) {
      const client = {
        handleIncomingMessage: () => {
          throw new Error("Message received before handler was registered");
        },
        signalClosure: () => {
          throw new Error("Closed before handler was registered");
        }
      };
      client.signalClosure = server$1.opened(
        {
          protocol: server.handleProtocols(
            peer.request.headers.get("sec-websocket-protocol") ?? ""
          ) || "",
          send: async (message) => {
            if (clients.has(peer)) {
              peer.send(message);
            }
          },
          close: (code, reason) => {
            if (clients.has(peer)) {
              peer.close(code, reason);
            }
          },
          onMessage: (cb) => {
            client.handleIncomingMessage = cb;
          }
        },
        { socket: peer.websocket }
      );
      clients.set(peer, client);
    },
    async message(peer, message) {
      const client = clients.get(peer);
      if (!client) throw new Error("Message received for a missing client");
      try {
        await client.handleIncomingMessage(message.text());
      } catch (err) {
        console.error(
          "Internal error occurred during message handling. Please check your implementation.",
          err
        );
        peer.close(
          common.CloseCode.InternalServerError,
          isProd ? "Internal server error" : common.limitCloseReason(
            err instanceof Error ? err.message : String(err),
            "Internal server error"
          )
        );
      }
    },
    close(peer, details) {
      const client = clients.get(peer);
      if (!client) throw new Error("Closing a missing client");
      client.signalClosure(
        details?.code ?? 1e3,
        details.reason || "Connection closed"
      );
      clients.delete(peer);
    },
    error(peer, error) {
      console.error(
        "Internal error emitted on the WebSocket socket. Please check your implementation.",
        error
      );
      peer.close(common.CloseCode.InternalServerError, "Internal server error");
    }
  });
}

exports.makeHooks = makeHooks;
