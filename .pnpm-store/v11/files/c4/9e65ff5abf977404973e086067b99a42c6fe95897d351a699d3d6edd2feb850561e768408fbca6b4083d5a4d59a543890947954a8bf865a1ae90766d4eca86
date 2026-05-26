'use strict';

var graphql = require('graphql');
var common = require('./common-DqFHi7oM.cjs');

function makeServer(options) {
  const {
    schema,
    context,
    roots,
    validate,
    execute,
    subscribe,
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
      if (socket.protocol !== common.GRAPHQL_TRANSPORT_WS_PROTOCOL) {
        socket.close(
          common.CloseCode.SubprotocolNotAcceptable,
          "Subprotocol not acceptable"
        );
        return async (code, reason) => {
          await onClose?.(ctx, code, reason);
        };
      }
      const connectionInitWait = connectionInitWaitTimeout > 0 && isFinite(connectionInitWaitTimeout) ? setTimeout(() => {
        if (!ctx.connectionInitReceived)
          socket.close(
            common.CloseCode.ConnectionInitialisationTimeout,
            "Connection initialisation timeout"
          );
      }, connectionInitWaitTimeout) : null;
      socket.onMessage(async function onMessage(data) {
        let message;
        try {
          message = common.parseMessage(data, reviver);
        } catch (err) {
          return socket.close(common.CloseCode.BadRequest, "Invalid message received");
        }
        switch (message.type) {
          case common.MessageType.ConnectionInit: {
            if (ctx.connectionInitReceived)
              return socket.close(
                common.CloseCode.TooManyInitialisationRequests,
                "Too many initialisation requests"
              );
            ctx.connectionInitReceived = true;
            if (common.isObject(message.payload))
              ctx.connectionParams = message.payload;
            const permittedOrPayload = await onConnect?.(ctx);
            if (permittedOrPayload === false)
              return socket.close(common.CloseCode.Forbidden, "Forbidden");
            ctx.acknowledged = true;
            await socket.send(
              common.stringifyMessage(
                common.isObject(permittedOrPayload) ? {
                  type: common.MessageType.ConnectionAck,
                  payload: permittedOrPayload
                } : {
                  type: common.MessageType.ConnectionAck
                  // payload is completely absent if not provided
                },
                replacer
              )
            );
            return;
          }
          case common.MessageType.Ping: {
            if (socket.onPing)
              return await socket.onPing(message.payload);
            await socket.send(
              common.stringifyMessage(
                message.payload ? { type: common.MessageType.Pong, payload: message.payload } : {
                  type: common.MessageType.Pong
                  // payload is completely absent if not provided
                }
              )
            );
            return;
          }
          case common.MessageType.Pong:
            return await socket.onPong?.(message.payload);
          case common.MessageType.Subscribe: {
            if (!ctx.acknowledged)
              return socket.close(common.CloseCode.Unauthorized, "Unauthorized");
            const { id, payload } = message;
            if (id in ctx.subscriptions)
              return socket.close(
                common.CloseCode.SubscriberAlreadyExists,
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
                  common.stringifyMessage(
                    {
                      id: id2,
                      type: common.MessageType.Next,
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
                  common.stringifyMessage(
                    {
                      id: id2,
                      type: common.MessageType.Error,
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
                    common.stringifyMessage(
                      {
                        id: id2,
                        type: common.MessageType.Complete
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
                  document: graphql.parse(payload.query),
                  variableValues: payload.variables
                };
                execArgs = {
                  ...args,
                  schema: typeof schema === "function" ? await schema(ctx, id, payload, args) : schema
                };
                const validationErrors = (validate ?? graphql.validate)(
                  execArgs.schema,
                  execArgs.document
                );
                if (validationErrors.length > 0)
                  return id in ctx.subscriptions ? await emit.error(validationErrors, message) : void 0;
              }
              const operationAST = graphql.getOperationAST(
                execArgs.document,
                execArgs.operationName
              );
              if (!operationAST)
                return id in ctx.subscriptions ? await emit.error(
                  [new graphql.GraphQLError("Unable to identify operation")],
                  message
                ) : void 0;
              if (!("rootValue" in execArgs))
                execArgs.rootValue = roots?.[operationAST.operation];
              if (!("contextValue" in execArgs))
                execArgs.contextValue = typeof context === "function" ? await context(ctx, id, payload, execArgs) : context;
              let operationResult;
              if (operationAST.operation === "subscription")
                operationResult = await (subscribe ?? graphql.subscribe)(
                  execArgs
                );
              else
                operationResult = await (execute ?? graphql.execute)(execArgs);
              const maybeResult = await onOperation?.(
                ctx,
                id,
                payload,
                execArgs,
                operationResult
              );
              if (maybeResult) operationResult = maybeResult;
              if (common.isAsyncIterable(operationResult)) {
                if (!(id in ctx.subscriptions)) {
                  if (common.isAsyncGenerator(operationResult))
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
                        graphql.versionInfo.major >= 16 ? new graphql.GraphQLError(
                          originalError.message,
                          // @ts-ignore graphql@15 and less dont have the second arg as object (version is ensured by versionInfo.major check above)
                          { originalError }
                        ) : (
                          // versionInfo.major <= 15
                          new graphql.GraphQLError(
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
          case common.MessageType.Complete: {
            const subscription = ctx.subscriptions[message.id];
            delete ctx.subscriptions[message.id];
            if (common.isAsyncGenerator(subscription))
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
          Object.values(subs).filter(common.isAsyncGenerator).map((sub) => sub.return(void 0))
        );
        if (ctx.acknowledged) await onDisconnect?.(ctx, code, reason);
        await onClose?.(ctx, code, reason);
      };
    }
  };
}
function handleProtocols(protocols) {
  switch (true) {
    case (protocols instanceof Set && protocols.has(common.GRAPHQL_TRANSPORT_WS_PROTOCOL)):
    case (Array.isArray(protocols) && protocols.includes(common.GRAPHQL_TRANSPORT_WS_PROTOCOL)):
    case (typeof protocols === "string" && protocols.split(",").map((p) => p.trim()).includes(common.GRAPHQL_TRANSPORT_WS_PROTOCOL)):
      return common.GRAPHQL_TRANSPORT_WS_PROTOCOL;
    default:
      return false;
  }
}
function areGraphQLErrors(obj) {
  return Array.isArray(obj) && // must be at least one error
  obj.length > 0 && // error has at least a message
  obj.every((ob) => ob instanceof graphql.GraphQLError);
}

exports.areGraphQLErrors = areGraphQLErrors;
exports.handleProtocols = handleProtocols;
exports.makeServer = makeServer;
