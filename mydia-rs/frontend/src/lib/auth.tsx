import { createContext, useContext, type ReactNode } from "react";
import { useQuery } from "urql";
import { ViewerDocument } from "../graphql/generated/graphql";

interface Viewer {
  id: string;
  username: string;
  role: string;
}

interface AuthContextValue {
  viewer: Viewer | null;
  loading: boolean;
  isAdmin: boolean;
}

const AuthContext = createContext<AuthContextValue>({
  viewer: null,
  loading: true,
  isAdmin: false,
});

export function useViewer() {
  return useContext(AuthContext);
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [{ data, fetching }] = useQuery({ query: ViewerDocument });

  const viewer = data?.viewer ?? null;

  const value: AuthContextValue = {
    viewer,
    loading: fetching,
    isAdmin: viewer?.role === "admin",
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function RequireAuth({ children }: { children: ReactNode }) {
  const { viewer, loading } = useViewer();

  if (loading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  if (!viewer) {
    window.location.assign("/login");
    return null;
  }

  return <>{children}</>;
}

export function RequireAdmin({ children }: { children: ReactNode }) {
  const { viewer, loading, isAdmin } = useViewer();

  if (loading) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  if (!viewer) {
    window.location.assign("/login");
    return null;
  }

  if (!isAdmin) {
    window.location.assign("/");
    return null;
  }

  return <>{children}</>;
}
