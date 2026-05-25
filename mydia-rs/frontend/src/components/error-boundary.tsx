import { Component, type ErrorInfo, type ReactNode } from "react";

interface Props {
  children: ReactNode;
  fallback?: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
}

export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("ErrorBoundary caught:", error, info);
  }

  render() {
    if (this.state.hasError) {
      return (
        this.props.fallback ?? (
          <div className="flex items-center justify-center min-h-screen bg-base-200">
            <div className="alert alert-error max-w-md">
              <div>
                <h2 className="text-lg font-bold">Something went wrong</h2>
                <p className="text-sm mt-1">
                  {this.state.error?.message ?? "An unexpected error occurred."}
                </p>
                <button
                  className="btn btn-sm btn-ghost mt-3"
                  onClick={() => this.setState({ hasError: false, error: null })}
                >
                  Try again
                </button>
              </div>
            </div>
          </div>
        )
      );
    }

    return this.props.children;
  }
}
