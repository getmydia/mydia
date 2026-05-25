import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { GraphqlProvider } from "./lib/graphql/provider";
import { AuthProvider } from "./lib/auth";
import { App } from "./app";
import "./index.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <BrowserRouter>
      <GraphqlProvider>
        <AuthProvider>
          <App />
        </AuthProvider>
      </GraphqlProvider>
    </BrowserRouter>
  </StrictMode>,
);
