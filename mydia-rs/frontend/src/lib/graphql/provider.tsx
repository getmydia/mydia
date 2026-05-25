import { createClient, Provider as UrqlProvider } from "urql";
import type { ReactNode } from "react";
import { clientConfig } from "./client";

const client = createClient(clientConfig);

interface GraphqlProviderProps {
  children: ReactNode;
}

export function GraphqlProvider({ children }: GraphqlProviderProps) {
  return <UrqlProvider value={client}>{children}</UrqlProvider>;
}
