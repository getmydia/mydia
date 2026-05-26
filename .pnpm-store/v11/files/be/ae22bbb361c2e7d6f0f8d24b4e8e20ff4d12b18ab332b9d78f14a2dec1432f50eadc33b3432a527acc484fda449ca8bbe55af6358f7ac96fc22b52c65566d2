import { DisposableAsyncExecutor } from '@graphql-tools/utils';
import { DocumentNode } from 'graphql';
import { EventErrorListener, EventMessageListener, EventConnectingListener, EventOpenedListener, EventConnectedListener, EventPingListener, EventPongListener, EventClosedListener, Client } from 'graphql-ws';

interface GraphQLWSExecutorOptions {
    print?(doc: DocumentNode): string;
    /** The URL of the WebSocket server to connect to. */
    url: string;
    /**
     * Additional headers to include with the upgrade request.
     * It will never be sent again during the lifecycle of the socket.
     *
     * Warning: This is a noop in browser environments
     */
    headers?: Record<string, string>;
    /**
     * Optional parameters, passed through the `payload` field with the `ConnectionInit` message,
     * that the client specifies when establishing a connection with the server. You can use this
     * for securely passing arguments for authentication.
     */
    connectionParams?: Record<string, unknown> | (() => Record<string, unknown>);
    /**
     * How to establish the connection to the server, on-demand or eagerly.
     *
     * @default true
     */
    lazy?: boolean;
    /**
     * How long should the client wait before closing the socket after the last operation has
     * completed. This is meant to be used in combination with `lazy`. You might want to have
     * a calmdown time before actually closing the connection. Kinda' like a lazy close "debounce".
     *
     * @default 0
     */
    lazyCloseTimeout?: number;
    /**
     * Do not use this option unless you know what you are doing.
     * @internal
     */
    on?: Partial<{
        error: EventErrorListener;
        message: EventMessageListener;
        connecting: EventConnectingListener;
        opened: EventOpenedListener;
        connected: EventConnectedListener;
        ping: EventPingListener;
        pong: EventPongListener;
        closed: EventClosedListener;
    }> | undefined;
    /**
     * Do not use this option unless you know what you are doing.
     * @internal
     */
    onClient?: (client: Client) => void;
}
declare function buildGraphQLWSExecutor(clientOptionsOrClient: GraphQLWSExecutorOptions | Client): DisposableAsyncExecutor;

export { type GraphQLWSExecutorOptions, buildGraphQLWSExecutor };
