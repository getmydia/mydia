import { GraphQLSchema, ExecutionArgs, OperationTypeNode, validate, GraphQLError, GraphQLFormattedError, FormattedExecutionResult } from 'graphql';
import { E as ExecutionResult, b as ConnectionInitMessage, I as ID, f as SubscribePayload, J as JSONMessageReviver, j as JSONMessageReplacer, P as PingMessage, d as PongMessage, G as GRAPHQL_TRANSPORT_WS_PROTOCOL } from './common-DY-PBNYy.cjs';

/**
 *
 * server
 *
 */

/** @category Server */
type OperationResult = Promise<AsyncGenerator<ExecutionResult> | AsyncIterable<ExecutionResult> | ExecutionResult> | AsyncGenerator<ExecutionResult> | AsyncIterable<ExecutionResult> | ExecutionResult;
/**
 * A concrete GraphQL execution context value type.
 *
 * Mainly used because TypeScript collapses unions
 * with `any` or `unknown` to `any` or `unknown`. So,
 * we use a custom type to allow definitions such as
 * the `context` server option.
 *
 * @category Server
 */
type GraphQLExecutionContextValue = object | symbol | number | string | boolean | undefined | null;
/** @category Server */
interface ServerOptions<P extends ConnectionInitMessage['payload'] = ConnectionInitMessage['payload'], E = unknown> {
    /**
     * The GraphQL schema on which the operations
     * will be executed and validated against.
     *
     * If a function is provided, it will be called on
     * every subscription request allowing you to manipulate
     * schema dynamically.
     *
     * If the schema is left undefined, you're trusted to
     * provide one in the returned `ExecutionArgs` from the
     * `onSubscribe` callback.
     *
     * Throwing an error from within this function will
     * close the socket with the `Error` message
     * in the close event reason.
     */
    schema?: undefined | GraphQLSchema | ((ctx: Context<P, E>, id: string, payload: SubscribePayload, args: Omit<ExecutionArgs, 'schema'>) => Promise<GraphQLSchema> | GraphQLSchema);
    /**
     * A value which is provided to every resolver and holds
     * important contextual information like the currently
     * logged in user, or access to a database.
     *
     * If you return from `onSubscribe`, and the returned value is
     * missing the `contextValue` field, this context will be used
     * instead.
     *
     * If you use the function signature, the final execution arguments
     * will be passed in (also the returned value from `onSubscribe`).
     * Since the context is injected on every subscribe, the `SubscribeMessage`
     * with the regular `Context` will be passed in through the arguments too.
     *
     * Note that the context function is invoked on each operation only once.
     * Meaning, for subscriptions, only at the point of initialising the subscription;
     * not on every subscription event emission. Read more about the context lifecycle
     * in subscriptions here: https://github.com/graphql/graphql-js/issues/894.
     */
    context?: undefined | GraphQLExecutionContextValue | ((ctx: Context<P, E>, id: string, payload: SubscribePayload, args: ExecutionArgs) => Promise<GraphQLExecutionContextValue> | GraphQLExecutionContextValue);
    /**
     * The GraphQL root fields or resolvers to go
     * alongside the schema. Learn more about them
     * here: https://graphql.org/learn/execution/#root-fields-resolvers.
     *
     * If you return from `onSubscribe`, and the returned value is
     * missing the `rootValue` field, the relevant operation root
     * will be used instead.
     */
    roots?: undefined | {
        [operation in OperationTypeNode]?: Record<string, NonNullable<ExecutionArgs['rootValue']>>;
    };
    /**
     * A custom GraphQL validate function allowing you to apply your
     * own validation rules.
     *
     * Returned, non-empty, array of `GraphQLError`s will be communicated
     * to the client through the `ErrorMessage`. Use an empty array if the
     * document is valid and no errors have been encountered.
     *
     * Will not be used when implementing a custom `onSubscribe`.
     *
     * Throwing an error from within this function will close the socket
     * with the `Error` message in the close event reason.
     */
    validate?: undefined | typeof validate;
    /**
     * Is the `execute` function from GraphQL which is
     * used to execute the query and mutation operations.
     *
     * Throwing an error from within this function will
     * close the socket with the `Error` message
     * in the close event reason.
     */
    execute?: undefined | ((args: ExecutionArgs) => OperationResult);
    /**
     * Is the `subscribe` function from GraphQL which is
     * used to execute the subscription operation.
     *
     * Throwing an error from within this function will
     * close the socket with the `Error` message
     * in the close event reason.
     */
    subscribe?: undefined | ((args: ExecutionArgs) => OperationResult);
    /**
     * The amount of time for which the server will wait
     * for `ConnectionInit` message.
     *
     * Set the value to `Infinity`, `''`, `0`, `null` or `undefined` to skip waiting.
     *
     * If the wait timeout has passed and the client
     * has not sent the `ConnectionInit` message,
     * the server will terminate the socket by
     * dispatching a close event `4408: Connection initialisation timeout`
     *
     * @default 3_000 // 3 seconds
     */
    connectionInitWaitTimeout?: undefined | number;
    /**
     * Is the connection callback called when the
     * client requests the connection initialisation
     * through the message `ConnectionInit`.
     *
     * The message payload (`connectionParams` from the
     * client) is present in the `Context.connectionParams`.
     *
     * - Returning `true` or nothing from the callback will
     * allow the client to connect.
     *
     * - Returning `false` from the callback will
     * terminate the socket by dispatching the
     * close event `4403: Forbidden`.
     *
     * - Returning a `Record` from the callback will
     * allow the client to connect and pass the returned
     * value to the client through the optional `payload`
     * field in the `ConnectionAck` message.
     *
     * Throwing an error from within this function will
     * close the socket with the `Error` message
     * in the close event reason.
     */
    onConnect?: undefined | ((ctx: Context<P, E>) => Promise<Record<string, unknown> | boolean | void> | Record<string, unknown> | boolean | void);
    /**
     * Called when the client disconnects for whatever reason after
     * he successfully went through the connection initialisation phase.
     * Provides the close event too. Beware that this callback happens
     * AFTER all subscriptions have been gracefully completed and BEFORE
     * the `onClose` callback.
     *
     * If you are interested in tracking the subscriptions completions,
     * consider using the `onComplete` callback.
     *
     * This callback will be called EXCLUSIVELY if the client connection
     * is acknowledged. Meaning, `onConnect` will be called before the `onDisconnect`.
     *
     * For tracking socket closures at any point in time, regardless
     * of the connection state - consider using the `onClose` callback.
     */
    onDisconnect?: undefined | ((ctx: Context<P, E>, code?: number, reason?: string) => Promise<void> | void);
    /**
     * Called when the socket closes for whatever reason, at any
     * point in time. Provides the close event too. Beware
     * that this callback happens AFTER all subscriptions have
     * been gracefully completed and AFTER the `onDisconnect` callback.
     *
     * If you are interested in tracking the subscriptions completions,
     * consider using the `onComplete` callback.
     *
     * In comparison to `onDisconnect`, this callback will ALWAYS
     * be called, regardless if the user successfully went through
     * the connection initialisation or not. `onConnect` might not
     * called before the `onClose`.
     */
    onClose?: undefined | ((ctx: Context<P, E>, code?: number, reason?: string) => Promise<void> | void);
    /**
     * The subscribe callback executed right after
     * acknowledging the request before any payload
     * processing has been performed.
     *
     * If you return `ExecutionArgs` from the callback,
     * it will be used instead of trying to build one
     * internally. In this case, you are responsible
     * for providing a ready set of arguments which will
     * be directly plugged in the operation execution.
     *
     * Omitting the fields `contextValue` or `rootValue`
     * from the returned value will have the provided server
     * options fill in the gaps.
     *
     * To report GraphQL errors simply return an array
     * of them from the callback, they will be reported
     * to the client through the error message.
     *
     * Useful for preparing the execution arguments
     * following a custom logic. A typical use case are
     * persisted queries, you can identify the query from
     * the subscribe message and create the GraphQL operation
     * execution args which are then returned by the function.
     *
     * Throwing an error from within this function will
     * close the socket with the `Error` message
     * in the close event reason.
     */
    onSubscribe?: undefined | ((ctx: Context<P, E>, id: string, payload: SubscribePayload) => Promise<ExecutionArgs | readonly GraphQLError[] | void> | ExecutionArgs | readonly GraphQLError[] | void);
    /**
     * Executed after the operation call resolves. For streaming
     * operations, triggering this callback does not necessarily
     * mean that there is already a result available - it means
     * that the subscription process for the stream has resolved
     * and that the client is now subscribed.
     *
     * The `OperationResult` argument is the result of operation
     * execution. It can be an iterator or already a value.
     *
     * If you want the single result and the events from a streaming
     * operation, use the `onNext` callback.
     *
     * Use this callback to listen for subscribe operation and
     * execution result manipulation.
     *
     * Throwing an error from within this function will
     * close the socket with the `Error` message
     * in the close event reason.
     */
    onOperation?: undefined | ((ctx: Context<P, E>, id: string, payload: SubscribePayload, args: ExecutionArgs, result: OperationResult) => Promise<OperationResult | void> | OperationResult | void);
    /**
     * Executed after an error occurred right before it
     * has been dispatched to the client.
     *
     * Use this callback to format the outgoing GraphQL
     * errors before they reach the client.
     *
     * Returned result will be injected in the error message payload.
     *
     * Throwing an error from within this function will
     * close the socket with the `Error` message
     * in the close event reason.
     */
    onError?: undefined | ((ctx: Context<P, E>, id: string, payload: SubscribePayload, errors: readonly GraphQLError[]) => Promise<readonly GraphQLFormattedError[] | void> | readonly GraphQLFormattedError[] | void);
    /**
     * Executed after an operation has emitted a result right before
     * that result has been sent to the client. Results from both
     * single value and streaming operations will appear in this callback.
     *
     * Use this callback if you want to format the execution result
     * before it reaches the client.
     *
     * Returned result will be injected in the next message payload.
     *
     * Throwing an error from within this function will
     * close the socket with the `Error` message
     * in the close event reason.
     */
    onNext?: undefined | ((ctx: Context<P, E>, id: string, payload: SubscribePayload, args: ExecutionArgs, result: ExecutionResult) => Promise<FormattedExecutionResult | void> | FormattedExecutionResult | void);
    /**
     * The complete callback is executed after the
     * operation has completed right before sending
     * the complete message to the client.
     *
     * Throwing an error from within this function will
     * close the socket with the `Error` message
     * in the close event reason.
     *
     * Since the library makes sure to complete streaming
     * operations even after an abrupt closure, this callback
     * will still be called.
     */
    onComplete?: undefined | ((ctx: Context<P, E>, id: string, payload: SubscribePayload) => Promise<void> | void);
    /**
     * An optional override for the JSON.parse function used to hydrate
     * incoming messages to this server. Useful for parsing custom datatypes
     * out of the incoming JSON.
     */
    jsonMessageReviver?: undefined | JSONMessageReviver;
    /**
     * An optional override for the JSON.stringify function used to serialize
     * outgoing messages to from server. Useful for serializing custom
     * datatypes out to the client.
     */
    jsonMessageReplacer?: undefined | JSONMessageReplacer;
}
/** @category Server */
interface Server<E = undefined> {
    /**
     * New socket has been established. The lib will validate
     * the protocol and use the socket accordingly. Returned promise
     * will resolve after the socket closes.
     *
     * The second argument will be passed in the `extra` field
     * of the `Context`. You may pass the initial request or the
     * original WebSocket, if you need it down the road.
     *
     * Returns a function that should be called when the same socket
     * has been closed, for whatever reason. The close code and reason
     * must be passed for reporting to the `onDisconnect` callback. Returned
     * promise will resolve once the internal cleanup is complete.
     */
    opened(socket: WebSocket, ctxExtra: E): (code?: number, reason?: string) => Promise<void>;
}
/** @category Server */
interface WebSocket {
    /**
     * The subprotocol of the WebSocket. Will be used
     * to validate against the supported ones.
     */
    readonly protocol: string;
    /**
     * Sends a message through the socket. Will always
     * provide a `string` message.
     *
     * Please take care that the send is ready. Meaning,
     * only provide a truly OPEN socket through the `opened`
     * method of the `Server`.
     *
     * The returned promise is used to control the flow of data
     * (like handling backpressure).
     */
    send(data: string): Promise<void> | void;
    /**
     * Closes the socket gracefully. Will always provide
     * the appropriate code and close reason. `onDisconnect`
     * callback will be called.
     *
     * The returned promise is used to control the graceful
     * closure.
     */
    close(code?: number, reason?: string): Promise<void> | void;
    /**
     * Called when message is received. The library requires the data
     * to be a `string`.
     *
     * All operations requested from the client will block the promise until
     * completed, this means that the callback will not resolve until all
     * subscription events have been emitted (or until the client has completed
     * the stream), or until the query/mutation resolves.
     *
     * Exceptions raised during any phase of operation processing will
     * reject the callback's promise, catch them and communicate them
     * to your clients however you wish.
     */
    onMessage(cb: (data: string) => Promise<void>): void;
    /**
     * Implement a listener for the `PingMessage` sent from the client to the server.
     * If the client sent the ping with a payload, it will be passed through the
     * first argument.
     *
     * If this listener is implemented, the server will NOT automatically reply
     * to any pings from the client. Implementing it makes it your responsibility
     * to decide how and when to respond.
     */
    onPing?(payload: PingMessage['payload']): Promise<void> | void;
    /**
     * Implement a listener for the `PongMessage` sent from the client to the server.
     * If the client sent the pong with a payload, it will be passed through the
     * first argument.
     */
    onPong?(payload: PongMessage['payload']): Promise<void> | void;
}
/** @category Server */
interface Context<P extends ConnectionInitMessage['payload'] = ConnectionInitMessage['payload'], E = unknown> {
    /**
     * Indicates that the `ConnectionInit` message
     * has been received by the server. If this is
     * `true`, the client wont be kicked off after
     * the wait timeout has passed.
     */
    readonly connectionInitReceived: boolean;
    /**
     * Indicates that the connection was acknowledged
     * by having dispatched the `ConnectionAck` message
     * to the related client.
     */
    readonly acknowledged: boolean;
    /** The parameters passed during the connection initialisation. */
    readonly connectionParams?: Readonly<P>;
    /**
     * Holds the active subscriptions for this context. **All operations**
     * that are taking place are aggregated here. The user is _subscribed_
     * to an operation when waiting for result(s).
     *
     * If the subscription behind an ID is an `AsyncIterator` - the operation
     * is streaming; on the contrary, if the subscription is `null` - it is simply
     * a reservation, meaning - the operation resolves to a single result or is still
     * pending/being prepared.
     */
    readonly subscriptions: Record<ID, AsyncGenerator<unknown> | AsyncIterable<unknown> | null>;
    /**
     * An extra field where you can store your own context values
     * to pass between callbacks.
     */
    extra: E;
}
/**
 * Makes a Protocol compliant WebSocket GraphQL server. The server
 * is actually an API which is to be used with your favourite WebSocket
 * server library!
 *
 * Read more about the [GraphQL over WebSocket Protocol](https://github.com/graphql/graphql-over-http/blob/main/rfcs/GraphQLOverWebSocket.md).
 *
 * @category Server
 */
declare function makeServer<P extends ConnectionInitMessage['payload'] = ConnectionInitMessage['payload'], E = unknown>(options: ServerOptions<P, E>): Server<E>;
/**
 * Helper utility for choosing the "graphql-transport-ws" subprotocol from
 * a set of WebSocket subprotocols.
 *
 * Accepts a set of already extracted WebSocket subprotocols or the raw
 * Sec-WebSocket-Protocol header value. In either case, if the right
 * protocol appears, it will be returned.
 *
 * By specification, the server should not provide a value with Sec-WebSocket-Protocol
 * if it does not agree with client's subprotocols. The client has a responsibility
 * to handle the connection afterwards.
 *
 * @category Server
 */
declare function handleProtocols(protocols: Set<string> | string[] | string): typeof GRAPHQL_TRANSPORT_WS_PROTOCOL | false;
/** @private */
declare function areGraphQLErrors(obj: unknown): obj is readonly GraphQLError[];

export { type Context as C, type GraphQLExecutionContextValue as G, type OperationResult as O, type ServerOptions as S, type WebSocket as W, type Server as a, areGraphQLErrors as b, handleProtocols as h, makeServer as m };
