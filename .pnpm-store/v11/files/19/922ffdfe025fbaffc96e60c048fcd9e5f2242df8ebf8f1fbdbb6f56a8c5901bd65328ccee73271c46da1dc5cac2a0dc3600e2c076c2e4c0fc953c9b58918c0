import * as crossws from 'crossws';
import { Peer } from 'crossws';
import { b as ConnectionInitMessage } from '../common-DY-PBNYy.cjs';
import { S as ServerOptions } from '../server-CrZ4ip-g.cjs';
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
    readonly socket: Peer['websocket'];
}
declare function makeHooks<P extends ConnectionInitMessage['payload'] = ConnectionInitMessage['payload'], E extends Record<PropertyKey, unknown> = Record<PropertyKey, never>>(options: ServerOptions<P, Extra & Partial<E>> & {
    /**
     * If the server is running in production. Defaults to read from `process.env.NODE_ENV`.
     * In production the server will not send error messages whichmight contain sensitive info to the client.
     */
    isProd?: boolean;
}): {
    open(peer: Peer<crossws.AdapterInternal>): void;
    message(peer: Peer<crossws.AdapterInternal>, message: crossws.Message): Promise<void>;
    close(peer: Peer<crossws.AdapterInternal>, details: {
        code?: number;
        reason?: string;
    }): void;
    error(peer: Peer<crossws.AdapterInternal>, error: crossws.WSError): void;
};

export { type Extra, makeHooks };
