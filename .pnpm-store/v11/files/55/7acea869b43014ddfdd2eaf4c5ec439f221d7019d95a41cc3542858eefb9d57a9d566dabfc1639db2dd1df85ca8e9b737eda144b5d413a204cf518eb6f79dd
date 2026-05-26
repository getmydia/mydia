import { parse, validate, getOperationAST, GraphQLError, subscribe, execute, versionInfo } from 'graphql';
import { G as GRAPHQL_TRANSPORT_WS_PROTOCOL, C as CloseCode, p as parseMessage, M as MessageType, a as isAsyncGenerator, b as isAsyncIterable, s as stringifyMessage, i as isObject } from './common-CGW11Fyb.js';

function makeServer(options) {
  const {
    schema,
    context,
    roots,
    validate: validate$1,
    execute: execute$1,
    subscribe: subscribe$1,
    connectionInitWaitTimeout = 3e3,
    // 3 seconds
    onConnect,
    onDisconnect,
    onClose,
    onSubscribe,
    onOperation,
    onNext,
    onError,
    onComplete,
    jsonMessageReviver: reviver,
    jsonMessageReplacer: replacer
  } = options;
  return {
    opened(socket, extra) {
      const ctx = {
        connectionInitReceived: false,
        acknowledged: false,
        subscriptions: {},
        extra
      };
      if (socket.protocol !== GRAPHQL_TRANSPORT_WS_PROTOCOL) {
        socket.close(
          CloseCode.SubprotocolNotAcceptable,
          "Subprotocol not acceptable"
        );
        return async (code, reason) => {
          await onClose?.(ctx, code, reason);
        };
      }
      const connectionInitWait = connectionInitWaitTimeout > 0 && isFinite(connectionInitWaitTimeout) ? setTimeout(() => {
        if (!ctx.connectionInitReceived)
          socket.close(
            CloseCode.ConnectionInitialisationTimeout,
            "Connection initialisation timeout"
          );
      }, connectionInitWaitTimeout) : null;
      socket.onMessage(async function onMessage(data) {
        let message;
        try {
          message = parseMessage(data, reviver);
        } catch (err) {
          return socket.close(CloseCode.BadRequest, "Invalid message received");
        }
        switch (message.type) {
          case MessageType.ConnectionInit: {
            if (ctx.connectionInitReceived)
              return socket.close(
                CloseCode.TooManyInitialisationRequests,
                "Too many initialisation requests"
              );
            ctx.connectionInitReceived = true;
            if (isObject(message.payload))
              ctx.connectionParams = message.payload;
            const permittedOrPayload = await onConnect?.(ctx);
            if (permittedOrPayload === false)
              return socket.close(CloseCode.Forbidden, "Forbidden");
            ctx.acknowledged = true;
            await socket.send(
              stringifyMessage(
                isObject(permittedOrPayload) ? {
                  type: MessageType.ConnectionAck,
                  payload: permittedOrPayload
                } : {
                  type: MessageType.ConnectionAck
                  // payload is completely absent if not provided
                },
                replacer
              )
            );
            return;
          }
          case MessageType.Ping: {
            if (socket.onPing)
              return await socket.onPing(message.payload);
            await socket.send(
              stringifyMessage(
                message.payload ? { type: MessageType.Pong, payload: message.payload } : {
                  type: MessageType.Pong
                  // payload is completely absent if not provided
                }
              )
            );
            return;
          }
          case MessageType.Pong:
            return await socket.onPong?.(message.payload);
          case MessageType.Subscribe: {
            if (!ctx.acknowledged)
              return socket.close(CloseCode.Unauthorized, "Unauthorized");
            const { id, payload } = message;
            if (id in ctx.subscriptions)
              return socket.close(
                CloseCode.SubscriberAlreadyExists,
                `Subscriber for ${id} already exists`
              );
            ctx.subscriptions[id] = null;
            const emit = {
              next: async (result, { id: id2, payload: payload2 }, args) => {
                const { errors, ...resultWithoutErrors } = result;
                const maybeResult = await onNext?.(
                  ctx,
                  id2,
                  payload2,
                  args,
                  result
                );
                await socket.send(
                  stringifyMessage(
                    {
                      id: id2,
                      type: MessageType.Next,
                      payload: maybeResult || {
                        ...resultWithoutErrors,
                        // omit errors completely if not defined
                        ...errors ? { errors: errors.map((e) => e.toJSON()) } : {}
                      }
                    },
                    replacer
                  )
                );
              },
              error: async (errors, { id: id2, payload: payload2 }) => {
                const maybeErrors = await onError?.(ctx, id2, payload2, errors);
                await socket.send(
                  stringifyMessage(
                    {
                      id: id2,
                      type: MessageType.Error,
                      payload: maybeErrors || errors.map((e) => e.toJSON())
                    },
                    replacer
                  )
                );
              },
              complete: async (notifyClient, { id: id2, payload: payload2 }) => {
                await onComplete?.(ctx, id2, payload2);
                if (notifyClient)
                  await socket.send(
                    stringifyMessage(
                      {
                        id: id2,
                        type: MessageType.Complete
                      },
                      replacer
                    )
                  );
              }
            };
            try {
              let execArgs;
              const maybeExecArgsOrErrors = await onSubscribe?.(
                ctx,
                message.id,
                message.payload
              );
              if (maybeExecArgsOrErrors) {
                if (areGraphQLErrors(maybeExecArgsOrErrors))
                  return id in ctx.subscriptions ? await emit.error(maybeExecArgsOrErrors, message) : void 0;
                else if (Array.isArray(maybeExecArgsOrErrors))
                  throw new Error(
                    "Invalid return value from onSubscribe hook, expected an array of GraphQLError objects"
                  );
                execArgs = maybeExecArgsOrErrors;
              } else {
                if (!schema)
                  throw new Error("The GraphQL schema is not provided");
                const args = {
                  operationName: payload.operationName,
                  document: parse(payload.query),
                  variableValues: payload.variables
                };
                execArgs = {
                  ...args,
                  schema: typeof schema === "function" ? await schema(ctx, id, payload, args) : schema
                };
                const validationErrors = (validate$1 ?? validate)(
                  execArgs.schema,
                  execArgs.document
                );
                if (validationErrors.length > 0)
                  return id in ctx.subscriptions ? await emit.error(validationErrors, message) : void 0;
              }
              const operationAST = getOperationAST(
                execArgs.document,
                execArgs.operationName
              );
              if (!operationAST)
                return id in ctx.subscriptions ? await emit.error(
                  [new GraphQLError("Unable to identify operation")],
                  message
                ) : void 0;
              if (!("rootValue" in execArgs))
                execArgs.rootValue = roots?.[operationAST.operation];
              if (!("contextValue" in execArgs))
                execArgs.contextValue = typeof context === "function" ? await context(ctx, id, payload, execArgs) : context;
              let operationResult;
              if (operationAST.operation === "subscription")
                operationResult = await (subscribe$1 ?? subscribe)(
                  execArgs
                );
              else
                operationResult = await (execute$1 ?? execute)(execArgs);
              const maybeResult = await onOperation?.(
                ctx,
                id,
                payload,
                execArgs,
                operationResult
              );
              if (maybeResult) operationResult = maybeResult;
              if (isAsyncIterable(operationResult)) {
                if (!(id in ctx.subscriptions)) {
                  if (isAsyncGenerator(operationResult))
                    operationResult.return(void 0);
                } else {
                  ctx.subscriptions[id] = operationResult;
                  try {
                    for await (const result of operationResult) {
                      await emit.next(result, message, execArgs);
                    }
                  } catch (err) {
                    const originalError = err instanceof Error ? err : new Error(String(err));
                    await emit.error(
                      [
                        versionInfo.major >= 16 ? new GraphQLError(
                          originalError.message,
                          // @ts-ignore graphql@15 and less dont have the second arg as object (version is ensured by versionInfo.major check above)
                          { originalError }
                        ) : (
                          // versionInfo.major <= 15
                          new GraphQLError(
                            originalError.message,
                            null,
                            null,
                            null,
                            null,
                            originalError
                          )
                        )
                      ],
                      message
                    );
                    delete ctx.subscriptions[id];
                  }
                }
              } else {
                if (id in ctx.subscriptions)
                  await emit.next(operationResult, message, execArgs);
              }
              await emit.complete(id in ctx.subscriptions, message);
            } finally {
              delete ctx.subscriptions[id];
            }
            return;
          }
          case MessageType.Complete: {
            const subscription = ctx.subscriptions[message.id];
            delete ctx.subscriptions[message.id];
            if (isAsyncGenerator(subscription))
              await subscription.return(void 0);
            return;
          }
          default:
            throw new Error(
              `Unexpected message of type ${message.type} received`
            );
        }
      });
      return async (code, reason) => {
        if (connectionInitWait) clearTimeout(connectionInitWait);
        const subs = { ...ctx.subscriptions };
        ctx.subscriptions = {};
        await Promise.all(
          Object.values(subs).filter(isAsyncGenerator).map((sub) => sub.return(void 0))
        );
        if (ctx.acknowledged) await onDisconnect?.(ctx, code, reason);
        await onClose?.(ctx, code, reason);
      };
    }
  };
}
function handleProtocols(protocols) {
  switch (true) {
    case (protocols instanceof Set && protocols.has(GRAPHQL_TRANSPORT_WS_PROTOCOL)):
    case (Array.isArray(protocols) && protocols.includes(GRAPHQL_TRANSPORT_WS_PROTOCOL)):
    case (typeof protocols === "string" && protocols.split(",").map((p) => p.trim()).includes(GRAPHQL_TRANSPORT_WS_PROTOCOL)):
      return GRAPHQL_TRANSPORT_WS_PROTOCOL;
    default:
      return false;
  }
}
function areGraphQLErrors(obj) {
  return Array.isArray(obj) && // must be at least one error
  obj.length > 0 && // error has at least a message
  obj.every((ob) => ob instanceof GraphQLError);
}

export { areGraphQLErrors as a, handleProtocols as h, makeServer as m };
