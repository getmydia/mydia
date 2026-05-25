import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { GraphqlProvider } from "./lib/graphql/provider";
import { AuthProvider } from "./lib/auth";
import { ThemeProvider } from "./lib/theme";
import { ErrorBoundary } from "./components/error-boundary";
import { App } from "./app";
import "./index.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ErrorBoundary>
      <BrowserRouter>
        <ThemeProvider>
          <GraphqlProvider>
            <AuthProvider>
              <App />
            </AuthProvider>
          </GraphqlProvider>
        </ThemeProvider>
      </BrowserRouter>
    </ErrorBoundary>
  </StrictMode>,
);
