import { ServerWebSocket, WebSocketHandler } from 'bun';
import { b as ConnectionInitMessage } from '../common-DY-PBNYy.cjs';
import { S as ServerOptions } from '../server-CrZ4ip-g.cjs';
export { h as handleProtocols } from '../server-CrZ4ip-g.cjs';
import 'graphql';

/**
 * The extra that will be put in the `Context`.
 *
 * @category Server/bun
 */
interface Extra {
    /**
     * The actual socket connection between the server and the client.
     */
    readonly socket: ServerWebSocket;
}
/**
 * Use the server with [Bun](https://bun.sh/).
 * This is a basic starter, feel free to copy the code over and adjust it to your needs
 *
 * The WebSocket subprotocol is not available on the established socket and therefore
 * needs to be checked during the request handling.
 *
 * Additionally, the keep-alive logic _seems_ to be handled by Bun seeing that
 * they default [`sendPingsAutomatically` to `true`](https://github.com/oven-sh/bun/blob/6a163cf933542506354dc836bd92693bcae5939b/src/deps/uws.zig#L893).
 *
 * ```ts
 * import { makeHandler, handleProtocols } from 'graphql-ws/use/bun';
 * import { schema } from './my-schema';
 *
 * Bun.serve({
 *   fetch(req, server) {
 *     const [path, _search] = req.url.split('?');
 *     if (!path.endsWith('/graphql')) {
 *       return new Response('Not Found', { status: 404 });
 *     }
 *     if (req.headers.get('upgrade') != 'websocket') {
 *       return new Response('Upgrade Required', { status: 426 });
 *     }
 *     if (!handleProtocols(req.headers.get('sec-websocket-protocol') || '')) {
 *       return new Response('Bad Request', { status: 404 });
 *     }
 *     if (!server.upgrade(req)) {
 *       return new Response('Internal Server Error', { status: 500 });
 *     }
 *     return new Response();
 *   },
 *   websocket: makeHandler({ schema }),
 *   port: 4000,
 * });
 *
 * console.log('Listening to port 4000');
 * ```
 *
 * @category Server/bun
 */
declare function makeHandler<P extends ConnectionInitMessage['payload'] = ConnectionInitMessage['payload'], E extends Record<PropertyKey, unknown> = Record<PropertyKey, never>>(options: ServerOptions<P, Extra & Partial<E>>): WebSocketHandler;

export { type Extra, makeHandler };
