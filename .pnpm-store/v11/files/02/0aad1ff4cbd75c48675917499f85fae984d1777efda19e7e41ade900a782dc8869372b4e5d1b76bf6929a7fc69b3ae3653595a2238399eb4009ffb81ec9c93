import * as http from 'http';
import WebSocket from 'ws';
export { default as WebSocket } from 'ws';
import { b as ConnectionInitMessage, a as Disposable } from '../common-DY-PBNYy.cjs';
import { S as ServerOptions } from '../server-CrZ4ip-g.cjs';
import 'graphql';

type WebSocketServer = WebSocket.Server;

/**
 * The extra that will be put in the `Context`.
 *
 * @category Server/ws
 */
interface Extra {
    /**
     * The actual socket connection between the server and the client.
     */
    readonly socket: WebSocket;
    /**
     * The initial HTTP upgrade request before the actual
     * socket and connection is established.
     */
    readonly request: http.IncomingMessage;
}
/**
 * Use the server on a [ws](https://github.com/websockets/ws) ws server.
 * This is a basic starter, feel free to copy the code over and adjust it to your needs
 *
 * @category Server/ws
 */
declare function useServer<P extends ConnectionInitMessage['payload'] = ConnectionInitMessage['payload'], E extends Record<PropertyKey, unknown> = Record<PropertyKey, never>>(options: ServerOptions<P, Extra & Partial<E>>, ws: WebSocketServer, 
/**
 * The timeout between dispatched keep-alive messages. Internally uses the [ws Ping and Pongs](https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#pings_and_pongs_the_heartbeat_of_websockets)
 * to check that the link between the clients and the server is operating and to prevent the link
 * from being broken due to idling.
 *
 * @default 12_000 // 12 seconds
 */
keepAlive?: number): Disposable;

export { type Extra, type WebSocketServer, useServer };
