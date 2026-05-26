import http__default from 'http';
import * as uWS from 'uWebSockets.js';
import { b as ConnectionInitMessage } from '../common-DY-PBNYy.cjs';
import { S as ServerOptions } from '../server-CrZ4ip-g.cjs';
import 'graphql';

/**
 * The extra that will be put in the `Context`.
 *
 * @category Server/uWebSockets
 */
interface Extra extends UpgradeData {
    /**
     * The actual socket connection between the server and the client
     * with the upgrade data.
     */
    readonly socket: uWS.WebSocket<unknown> & UpgradeData;
}
/**
 * Data acquired during the HTTP upgrade callback from uWS.
 *
 * @category Server/uWebSockets
 */
interface UpgradeData {
    /**
     * The initial HTTP upgrade request before the actual
     * socket and connection is established.
     *
     * uWS's request is stack allocated and cannot be accessed
     * from outside of the internal upgrade; therefore, the persisted
     * request holds the relevant values extracted from the uWS's request
     * while it is accessible.
     */
    readonly persistedRequest: PersistedRequest;
}
/**
 * The initial HTTP upgrade request before the actual
 * socket and connection is established.
 *
 * uWS's request is stack allocated and cannot be accessed
 * from outside of the internal upgrade; therefore, the persisted
 * request holds relevant values extracted from the uWS's request
 * while it is accessible.
 *
 * @category Server/uWebSockets
 */
interface PersistedRequest {
    method: string;
    url: string;
    /** The raw query string (after the `?` sign) or empty string. */
    query: string;
    headers: http__default.IncomingHttpHeaders;
}
/**
 * Make the behaviour for using a [uWebSockets.js](https://github.com/uNetworking/uWebSockets.js) WebSocket server.
 * This is a basic starter, feel free to copy the code over and adjust it to your needs
 *
 * @category Server/uWebSockets
 */
declare function makeBehavior<P extends ConnectionInitMessage['payload'] = ConnectionInitMessage['payload'], E extends Record<PropertyKey, unknown> = Record<PropertyKey, never>>(options: ServerOptions<P, Extra & Partial<E>>, behavior?: uWS.WebSocketBehavior<unknown>, 
/**
 * The timout between dispatched keep-alive messages. Internally uses the [ws Ping and Pongs](https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API/Writing_WebSocket_servers#pings_and_pongs_the_heartbeat_of_websockets)
 * to check that the link between the clients and the server is operating and to prevent the link
 * from being broken due to idling.
 *
 * @default 12_000 // 12 seconds
 */
keepAlive?: number): uWS.WebSocketBehavior<unknown>;

export { type Extra, type PersistedRequest, type UpgradeData, makeBehavior };
