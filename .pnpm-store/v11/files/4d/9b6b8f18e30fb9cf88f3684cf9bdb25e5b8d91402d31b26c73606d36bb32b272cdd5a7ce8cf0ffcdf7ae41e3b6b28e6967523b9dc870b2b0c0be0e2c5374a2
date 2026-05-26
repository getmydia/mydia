import { C as CloseCode, D as DEPRECATED_GRAPHQL_WS_PROTOCOL } from '../common-CGW11Fyb.js';
export { G as GRAPHQL_TRANSPORT_WS_PROTOCOL } from '../common-CGW11Fyb.js';
import { m as makeServer } from '../server-Q0e3NPty.js';
import 'graphql';

function makeHandler(options) {
  const server = makeServer(options);
  return function handle(socket) {
    socket.onerror = (err) => {
      console.error(
        "Internal error emitted on the WebSocket socket. Please check your implementation.",
        err
      );
      socket.close(CloseCode.InternalServerError, "Internal server error");
    };
    let closed = () => {
    };
    socket.onopen = () => {
      closed = server.opened(
        {
          protocol: socket.protocol,
          send: (msg) => socket.send(msg),
          close: (code, reason) => socket.close(code, reason),
          onMessage: (cb) => {
            socket.onmessage = async (event) => {
              try {
                await cb(String(event.data));
              } catch (err) {
                console.error(
                  "Internal error occurred during message handling. Please check your implementation.",
                  err
                );
                socket.close(
                  CloseCode.InternalServerError,
                  "Internal server error"
                );
              }
            };
          }
        },
        { socket }
      );
    };
    socket.onclose = (event) => {
      if (event.code === CloseCode.SubprotocolNotAcceptable && socket.protocol === DEPRECATED_GRAPHQL_WS_PROTOCOL)
        console.warn(
          `Client provided the unsupported and deprecated subprotocol "${socket.protocol}" used by subscriptions-transport-ws.Please see https://www.apollographql.com/docs/apollo-server/data/subscriptions/#switching-from-subscriptions-transport-ws.`
        );
      closed(event.code, event.reason);
    };
  };
}

export { makeHandler };
