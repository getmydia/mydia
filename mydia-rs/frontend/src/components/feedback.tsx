import { useState, type ReactNode } from "react";

type AlertKind = "info" | "success" | "warning" | "error";

interface AlertProps {
  kind?: AlertKind;
  title?: string;
  children: ReactNode;
  onClose?: () => void;
}

export function Alert({
  kind = "info",
  title,
  children,
  onClose,
}: AlertProps) {
  const [visible, setVisible] = useState(true);

  if (!visible) return null;

  const handleClose = () => {
    setVisible(false);
    onClose?.();
  };

  return (
    <div className={["alert", `alert-${kind}`].join(" ")}>
      <div className="flex-1">
        {title && <h3 className="font-bold text-sm">{title}</h3>}
        <div className="text-xs">{children}</div>
      </div>
      {onClose && (
        <button
          className="btn btn-ghost btn-xs"
          onClick={handleClose}
          aria-label="Dismiss"
        >
          ×
        </button>
      )}
    </div>
  );
}

const toastTimers = new Map<string, ReturnType<typeof setTimeout>>();

interface ToastOptions {
  kind?: AlertKind;
  duration?: number;
}

let addToastFn: ((message: string, opts?: ToastOptions) => void) | null = null;

export function setToastFunction(fn: (message: string, opts?: ToastOptions) => void) {
  addToastFn = fn;
}

export function pushToast(message: string, opts?: ToastOptions) {
  addToastFn?.(message, opts);
}

interface Toast {
  id: string;
  message: string;
  kind: AlertKind;
}

export function ToastContainer() {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const addToast = (message: string, opts?: ToastOptions) => {
    const id = crypto.randomUUID();
    const kind = opts?.kind ?? "info";
    const duration = opts?.duration ?? 5000;

    setToasts((prev) => [...prev, { id, message, kind }]);

    const timer = setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
      toastTimers.delete(id);
    }, duration);
    toastTimers.set(id, timer);
  };

  setToastFunction(addToast);

  return (
    <div className="toast toast-end toast-bottom z-50">
      {toasts.map((toast) => (
        <div key={toast.id} className={["alert", `alert-${toast.kind}`].join(" ")}>
          <span className="text-sm">{toast.message}</span>
        </div>
      ))}
    </div>
  );
}
