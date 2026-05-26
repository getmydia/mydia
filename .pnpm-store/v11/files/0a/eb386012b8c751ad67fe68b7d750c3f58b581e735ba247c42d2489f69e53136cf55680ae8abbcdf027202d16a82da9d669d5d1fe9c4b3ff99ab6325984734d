import { serializeExecutionRequest, defaultPrintFn } from '@graphql-tools/executor-common';
import { getOperationASTFromRequest } from '@graphql-tools/utils';
import { DisposableSymbols } from '@whatwg-node/disposablestack';
import { createClient } from 'graphql-ws';
import { WebSocket } from 'isows';

function isNode() {
  return typeof process !== "undefined" && process.versions && process.versions.node && typeof Bun === "undefined";
}
function isBrowser() {
  return typeof window !== "undefined";
}
function getNodeVer() {
  if (!isNode()) return { major: NaN, minor: NaN, patch: NaN };
  const [major, minor, patch] = process.versions.node.split(".").map(Number);
  return { major: major || NaN, minor: minor || NaN, patch: patch || NaN };
}

function isClient(client) {
  return "subscribe" in client;
}
function buildGraphQLWSExecutor(clientOptionsOrClient) {
  let graphqlWSClient;
  let executorConnectionParams = {};
  let printFn = defaultPrintFn;
  if (isClient(clientOptionsOrClient)) {
    graphqlWSClient = clientOptionsOrClient;
  } else {
    if (clientOptionsOrClient.print) {
      printFn = clientOptionsOrClient.print;
    }
    const headers = clientOptionsOrClient.headers;
    const webSocketImpl = headers ? class WebSocketWithHeaders extends WebSocket {
      constructor(url, protocol) {
        if (isBrowser()) {
          super(url, protocol);
        } else if (getNodeVer().major < 22) {
          super(
            url,
            protocol,
            // @ts-expect-error will require('ws') and headers are passed like this
            { headers }
          );
        } else {
          super(url, {
            // we pass both protocols and protocol to satisfy different implementations
            // @ts-expect-error rest of environments supporting native WebSocket (Deno, Bun, Node 22+)
            protocols: [protocol],
            protocol,
            headers
          });
        }
      }
    } : WebSocket;
    graphqlWSClient = createClient({
      url: clientOptionsOrClient.url,
      webSocketImpl,
      lazy: clientOptionsOrClient.lazy !== false,
      lazyCloseTimeout: clientOptionsOrClient.lazyCloseTimeout || 0,
      connectionParams: () => {
        const optionsConnectionParams = (typeof clientOptionsOrClient.connectionParams === "function" ? clientOptionsOrClient.connectionParams() : clientOptionsOrClient.connectionParams) || {};
        return Object.assign(optionsConnectionParams, executorConnectionParams);
      },
      on: clientOptionsOrClient.on
    });
    if (clientOptionsOrClient.onClient) {
      clientOptionsOrClient.onClient(graphqlWSClient);
    }
  }
  const executor = function GraphQLWSExecutor(executionRequest) {
    const {
      extensions,
      operationType = getOperationASTFromRequest(executionRequest).operation,
      info,
      signal = info?.signal
    } = executionRequest;
    if (extensions?.["connectionParams"] && typeof extensions?.["connectionParams"] === "object") {
      executorConnectionParams = Object.assign(
        executorConnectionParams,
        extensions["connectionParams"]
      );
    }
    const iterableIterator = graphqlWSClient.iterate(
      serializeExecutionRequest({ executionRequest, printFn })
    );
    if (iterableIterator.return && signal) {
      signal.addEventListener(
        "abort",
        () => {
          iterableIterator.return?.();
        },
        { once: true }
      );
    }
    if (operationType === "subscription") {
      return iterableIterator;
    }
    return iterableIterator.next().then(({ value }) => value);
  };
  Object.defineProperty(executor, DisposableSymbols.asyncDispose, {
    value: function disposeWS() {
      return graphqlWSClient.dispose();
    }
  });
  return executor;
}

export { buildGraphQLWSExecutor };
