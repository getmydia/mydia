import { cacheExchange, fetchExchange, subscriptionExchange } from "urql";
import { createClient as createWSClient } from "graphql-ws";

const wsClient = createWSClient({
  url: `${window.location.protocol === "https:" ? "wss:" : "ws:"}//${window.location.host}/graphql/ws`,
  lazy: true,
  retryAttempts: 5,
});

const customFetch = (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
  const headers = new Headers(init?.headers);
  if (!headers.has("X-Mydia-Client")) {
    headers.set("X-Mydia-Client", "web");
  }
  return fetch(input, { ...init, headers });
};

export const clientConfig = {
  url: "/graphql",
  exchanges: [
    cacheExchange,
    fetchExchange,
    subscriptionExchange({
      forwardSubscription(request) {
        const input = { ...request, query: request.query || "" };
        return {
          subscribe(sink) {
            const dispose = wsClient.subscribe(input, sink);
            return {
              unsubscribe: dispose,
            };
          },
        };
      },
    }),
  ],
  fetchOptions: {
    credentials: "include" as const,
  },
  fetch: customFetch as typeof fetch,
  requestPolicy: "cache-and-network" as const,
};
