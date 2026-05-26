import { b as ConnectionInitMessage } from '../common-DY-PBNYy.js';
export { G as GRAPHQL_TRANSPORT_WS_PROTOCOL } from '../common-DY-PBNYy.js';
import { S as ServerOptions } from '../server-CvxoLxzz.js';
import 'graphql';

/**
 * The extra that will be put in the `Context`.
 *
 * @category Server/deno
 */
interface Extra {
    /**
     * The actual socket connection between the server and the client.
     */
    readonly socket: WebSocket;
}
/**
 * Use the server with [Deno](https://deno.com/).
 * This is a basic starter, feel free to copy the code over and adjust it to your needs.
 *
 * The keep-alive is set in `Deno.upgradeWebSocket` during the upgrade.
 *
 * Additionally, the required WebSocket protocol is also defined during the upgrade,
 * the correct example being:
 *
 * ```ts
 * import { serve } from 'https://deno.land/std/http/mod.ts';
 * import {
 *   makeHandler,
 *   GRAPHQL_TRANSPORT_WS_PROTOCOL,
 * } from 'https://esm.sh/graphql-ws/use/deno';
 * import { schema } from './my-schema.ts';
 *
 * const handler = makeHandler({ schema });
 *
 * serve(
 *   (req: Request) => {
 *     const [path, _search] = req.url.split('?');
 *     if (!path.endsWith('/graphql')) {
 *       return new Response('Not Found', { status: 404 });
 *     }
 *     if (req.headers.get('upgrade') != 'websocket') {
 *       return new Response('Upgrade Required', { status: 426 });
 *     }
 *     const { socket, response } = Deno.upgradeWebSocket(req, {
 *       protocol: GRAPHQL_TRANSPORT_WS_PROTOCOL,
 *       idleTimeout: 12_000,
 *     });
 *     handler(socket);
 *     return response;
 *   },
 *   { port: 4000 },
 * );
 * ```
 *
 * @category Server/deno
 */
declare function makeHandler<P extends ConnectionInitMessage['payload'] = ConnectionInitMessage['payload'], E extends Record<PropertyKey, unknown> = Record<PropertyKey, never>>(options: ServerOptions<P, Extra & Partial<E>>): (socket: WebSocket) => void;

export { type Extra, makeHandler };
