import { G as GRAPHQL_TRANSPORT_WS_PROTOCOL } from '../common-CGW11Fyb.js';
import { m as makeServer } from '../server-Q0e3NPty.js';
export { h as handleProtocols } from '../server-Q0e3NPty.js';
import 'graphql';

function makeHandler(options) {
  const server = makeServer(options);
  const clients = /* @__PURE__ */ new WeakMap();
  return {
    open(ws) {
      const client = {
        handleMessage: () => {
          throw new Error("Message received before handler was registered");
        },
        closed: () => {
          throw new Error("Closed before handler was registered");
        }
      };
      client.closed = server.opened(
        {
          // TODO: use protocol on socket once Bun exposes it
          protocol: GRAPHQL_TRANSPORT_WS_PROTOCOL,
          send: async (message) => {
            if (clients.has(ws)) {
              ws.sendText(message);
            }
          },
          close: (code, reason) => {
            if (clients.has(ws)) {
              ws.close(code, reason);
            }
          },
          onMessage: (cb) => client.handleMessage = cb
        },
        { socket: ws }
      );
      clients.set(ws, client);
    },
    message(ws, message) {
      const client = clients.get(ws);
      if (!client) throw new Error("Message received for a missing client");
      return client.handleMessage(String(message));
    },
    close(ws, code, message) {
      const client = clients.get(ws);
      if (!client) throw new Error("Closing a missing client");
      return client.closed(code, message);
    }
  };
}

export { makeHandler };
