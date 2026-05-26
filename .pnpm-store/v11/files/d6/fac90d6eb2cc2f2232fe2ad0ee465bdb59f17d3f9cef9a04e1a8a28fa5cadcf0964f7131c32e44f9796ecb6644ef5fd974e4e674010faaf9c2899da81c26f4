import { C as CloseCode, l as limitCloseReason } from '../common-CGW11Fyb.js';
import { m as makeServer, h as handleProtocols } from '../server-Q0e3NPty.js';
import 'graphql';

function makeBehavior(options, behavior = {}, keepAlive = 12e3) {
  const isProd = process.env.NODE_ENV === "production";
  const server = makeServer(options);
  const clients = /* @__PURE__ */ new Map();
  let onDrain = () => {
  };
  return {
    ...behavior,
    pong(...args) {
      behavior.pong?.(...args);
      const [socket] = args;
      const client = clients.get(socket);
      if (!client) throw new Error("Pong received for a missing client");
      if (client.pongWaitTimeout) {
        clearTimeout(client.pongWaitTimeout);
        client.pongWaitTimeout = null;
      }
    },
    upgrade(...args) {
      behavior.upgrade?.(...args);
      const [res, req, context] = args;
      const headers = {};
      req.forEach((key, value) => {
        headers[key] = value;
      });
      res.upgrade(
        {
          persistedRequest: {
            method: req.getMethod(),
            url: req.getUrl(),
            query: req.getQuery(),
            headers
          }
        },
        req.getHeader("sec-websocket-key"),
        handleProtocols(req.getHeader("sec-websocket-protocol")) || new Uint8Array(),
        req.getHeader("sec-websocket-extensions"),
        context
      );
    },
    open(...args) {
      behavior.open?.(...args);
      const socket = args[0];
      const persistedRequest = socket.persistedRequest;
      const client = {
        pingInterval: null,
        pongWaitTimeout: null,
        handleMessage: () => {
          throw new Error("Message received before handler was registered");
        },
        closed: () => {
          throw new Error("Closed before handler was registered");
        }
      };
      client.closed = server.opened(
        {
          protocol: handleProtocols(
            persistedRequest.headers["sec-websocket-protocol"] || ""
          ) || "",
          send: async (message) => {
            if (!clients.has(socket)) return;
            if (!socket.send(message))
              await new Promise((resolve) => onDrain = resolve);
          },
          close: (code, reason) => {
            setImmediate(() => {
              if (clients.has(socket)) socket.end(code, reason);
            });
          },
          onMessage: (cb) => client.handleMessage = cb
        },
        { socket, persistedRequest }
      );
      if (keepAlive > 0 && isFinite(keepAlive)) {
        client.pingInterval = setInterval(() => {
          client.pongWaitTimeout = setTimeout(() => socket.close(), keepAlive);
          socket.ping();
        }, keepAlive);
      }
      clients.set(socket, client);
    },
    drain(...args) {
      behavior.drain?.(...args);
      onDrain();
    },
    async message(...args) {
      behavior.message?.(...args);
      const [socket, message] = args;
      const client = clients.get(socket);
      if (!client) throw new Error("Message received for a missing client");
      try {
        await client.handleMessage(Buffer.from(message).toString());
      } catch (err) {
        console.error(
          "Internal error occurred during message handling. Please check your implementation.",
          err
        );
        socket.end(
          CloseCode.InternalServerError,
          isProd ? "Internal server error" : limitCloseReason(
            err instanceof Error ? err.message : String(err),
            "Internal server error"
          )
        );
      }
    },
    close(...args) {
      behavior.close?.(...args);
      const [socket, code, message] = args;
      const client = clients.get(socket);
      if (!client) throw new Error("Closing a missing client");
      if (client.pongWaitTimeout) clearTimeout(client.pongWaitTimeout);
      if (client.pingInterval) clearTimeout(client.pingInterval);
      client.closed(code, Buffer.from(message).toString());
      clients.delete(socket);
    }
  };
}

export { makeBehavior };
