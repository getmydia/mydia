import { print } from 'graphql';
import WebSocket from 'isomorphic-ws';
import { observableToAsyncIterable, } from '@graphql-tools/utils';
export var LEGACY_WS;
(function (LEGACY_WS) {
    LEGACY_WS["CONNECTION_INIT"] = "connection_init";
    LEGACY_WS["CONNECTION_ACK"] = "connection_ack";
    LEGACY_WS["CONNECTION_ERROR"] = "connection_error";
    LEGACY_WS["CONNECTION_KEEP_ALIVE"] = "ka";
    LEGACY_WS["START"] = "start";
    LEGACY_WS["STOP"] = "stop";
    LEGACY_WS["CONNECTION_TERMINATE"] = "connection_terminate";
    LEGACY_WS["DATA"] = "data";
    LEGACY_WS["ERROR"] = "error";
    LEGACY_WS["COMPLETE"] = "complete";
})(LEGACY_WS || (LEGACY_WS = {}));
export function buildWSLegacyExecutor(subscriptionsEndpoint, WebSocketImpl, options) {
    let executorConnectionParams = {};
    let websocket = null;
    const ensureWebsocket = (errorHandler = err => console.error(err)) => {
        if (websocket == null || websocket.readyState !== WebSocket.OPEN) {
            websocket = new WebSocketImpl(subscriptionsEndpoint, 'graphql-ws', {
                followRedirects: true,
                headers: options?.headers,
                rejectUnauthorized: false,
                skipUTF8Validation: true,
            });
            websocket.onopen = () => {
                let payload = {};
                switch (typeof options?.connectionParams) {
                    case 'function':
                        payload = options?.connectionParams();
                        break;
                    case 'object':
                        payload = options?.connectionParams;
                        break;
                }
                payload = Object.assign(payload, executorConnectionParams);
                websocket.send(JSON.stringify({
                    type: LEGACY_WS.CONNECTION_INIT,
                    payload,
                }), (error) => {
                    if (error) {
                        errorHandler(error);
                    }
                });
            };
            websocket.onerror = event => {
                errorHandler(event.error);
            };
            websocket.onclose = () => {
                websocket = null;
            };
        }
    };
    const cleanupWebsocket = () => {
        if (websocket != null) {
            websocket.send(JSON.stringify({
                type: LEGACY_WS.CONNECTION_TERMINATE,
            }));
            websocket.terminate();
            websocket = null;
        }
    };
    const executor = function legacyExecutor(request) {
        // additional connection params can be supplied through the "connectionParams" field in extensions.
        // TODO: connection params only from the FIRST operation in lazy mode will be used (detect connectionParams changes and reconnect, too implicit?)
        if (request.extensions?.['connectionParams'] &&
            typeof request.extensions?.['connectionParams'] === 'object') {
            executorConnectionParams = Object.assign(executorConnectionParams, request.extensions['connectionParams']);
        }
        const id = Date.now().toString();
        return observableToAsyncIterable({
            subscribe(observer) {
                function errorHandler(err) {
                    observer.error(err);
                }
                ensureWebsocket();
                if (websocket == null) {
                    throw new Error(`WebSocket connection is not found!`);
                }
                websocket.onmessage = event => {
                    const data = JSON.parse(event.data.toString('utf-8'));
                    switch (data.type) {
                        case LEGACY_WS.CONNECTION_ACK: {
                            if (websocket == null) {
                                throw new Error(`WebSocket connection is not found!`);
                            }
                            websocket.send(JSON.stringify({
                                type: LEGACY_WS.START,
                                id,
                                payload: {
                                    query: print(request.document),
                                    variables: request.variables,
                                    operationName: request.operationName,
                                },
                            }), (error) => {
                                if (error) {
                                    errorHandler(error);
                                }
                            });
                            break;
                        }
                        case LEGACY_WS.CONNECTION_ERROR: {
                            observer.error(data.payload);
                            break;
                        }
                        case LEGACY_WS.CONNECTION_KEEP_ALIVE: {
                            break;
                        }
                        case LEGACY_WS.DATA: {
                            observer.next(data.payload);
                            break;
                        }
                        case LEGACY_WS.COMPLETE: {
                            if (websocket != null) {
                                websocket.send(JSON.stringify({
                                    type: LEGACY_WS.CONNECTION_TERMINATE,
                                }), (error) => {
                                    if (error) {
                                        errorHandler(error);
                                    }
                                });
                            }
                            observer.complete();
                            cleanupWebsocket();
                            break;
                        }
                    }
                };
                return {
                    unsubscribe: () => {
                        if (websocket?.readyState === WebSocket.OPEN) {
                            websocket?.send(JSON.stringify({
                                type: LEGACY_WS.STOP,
                                id,
                            }));
                        }
                        cleanupWebsocket();
                    },
                };
            },
        });
    };
    executor[Symbol.dispose] = cleanupWebsocket;
    return executor;
}
