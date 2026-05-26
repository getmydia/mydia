'use strict';

var common = require('../common-DqFHi7oM.cjs');
var server = require('../server-BVbx-kML.cjs');
require('graphql');

function useServer(options, ws, keepAlive = 12e3) {
  const isProd = process.env.NODE_ENV === "production";
  const server$1 = server.makeServer(options);
  ws.options.handleProtocols = server.handleProtocols;
  ws.once("error", (err) => {
    console.error(
      "Internal error emitted on the WebSocket server. Please check your implementation.",
      err
    );
    let firstErr = null;
    for (const client of ws.clients) {
      try {
        client.close(
          common.CloseCode.InternalServerError,
          isProd ? "Internal server error" : common.limitCloseReason(
            err instanceof Error ? err.message : String(err),
            "Internal server error"
          )
        );
      } catch (err2) {
        firstErr = firstErr ?? err2;
      }
    }
    if (firstErr) throw firstErr;
  });
  ws.on("connection", (socket, request) => {
    socket.once("error", (err) => {
      console.error(
        "Internal error emitted on a WebSocket socket. Please check your implementation.",
        err
      );
      socket.close(
        common.CloseCode.InternalServerError,
        isProd ? "Internal server error" : common.limitCloseReason(
          err instanceof Error ? err.message : String(err),
          "Internal server error"
        )
      );
    });
    let pongWait = null;
    const pingInterval = keepAlive > 0 && isFinite(keepAlive) ? setInterval(() => {
      if (socket.readyState === socket.OPEN) {
        pongWait = setTimeout(() => {
          socket.terminate();
        }, keepAlive);
        socket.once("pong", () => {
          if (pongWait) {
            clearTimeout(pongWait);
            pongWait = null;
          }
        });
        socket.ping();
      }
    }, keepAlive) : null;
    const closed = server$1.opened(
      {
        protocol: socket.protocol,
        send: (data) => new Promise((resolve, reject) => {
          if (socket.readyState !== socket.OPEN) return resolve();
          socket.send(data, (err) => err ? reject(err) : resolve());
        }),
        close: (code, reason) => socket.close(code, reason),
        onMessage: (cb) => socket.on("message", async (event) => {
          try {
            await cb(String(event));
          } catch (err) {
            console.error(
              "Internal error occurred during message handling. Please check your implementation.",
              err
            );
            socket.close(
              common.CloseCode.InternalServerError,
              isProd ? "Internal server error" : common.limitCloseReason(
                err instanceof Error ? err.message : String(err),
                "Internal server error"
              )
            );
          }
        })
      },
      { socket, request }
    );
    socket.once("close", (code, reason) => {
      if (pongWait) clearTimeout(pongWait);
      if (pingInterval) clearInterval(pingInterval);
      if (!isProd && code === common.CloseCode.SubprotocolNotAcceptable && socket.protocol === common.DEPRECATED_GRAPHQL_WS_PROTOCOL)
        console.warn(
          `Client provided the unsupported and deprecated subprotocol "${socket.protocol}" used by subscriptions-transport-ws.Please see https://www.apollographql.com/docs/apollo-server/data/subscriptions/#switching-from-subscriptions-transport-ws.`
        );
      closed(code, String(reason));
    });
  });
  return {
    dispose: async () => {
      for (const client of ws.clients) {
        client.close(1001, "Going away");
      }
      ws.removeAllListeners();
      await new Promise((resolve, reject) => {
        ws.close((err) => err ? reject(err) : resolve());
      });
    }
  };
}

exports.useServer = useServer;
