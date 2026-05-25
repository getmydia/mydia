import {
  forwardRef,
  useImperativeHandle,
  useRef,
  useEffect,
  type ReactNode,
  type MouseEvent,
} from "react";

export interface ModalHandle {
  show: () => void;
  close: () => void;
}

interface ModalProps {
  id?: string;
  title?: string;
  children: ReactNode;
  onClose?: () => void;
}

export const Modal = forwardRef<ModalHandle, ModalProps>(
  ({ id = "modal-dialog", title, children, onClose }, ref) => {
    const dialogRef = useRef<HTMLDialogElement>(null);

    useImperativeHandle(ref, () => ({
      show() {
        dialogRef.current?.showModal();
      },
      close() {
        dialogRef.current?.close();
        onClose?.();
      },
    }));

    useEffect(() => {
      const el = dialogRef.current;
      if (!el) return;

      const handleClose = () => {
        onClose?.();
      };
      el.addEventListener("close", handleClose);
      return () => el.removeEventListener("close", handleClose);
    }, [onClose]);

    const handleBackdropClick = (e: MouseEvent<HTMLDialogElement>) => {
      if (e.target === dialogRef.current) {
        dialogRef.current?.close();
        onClose?.();
      }
    };

    return (
      <dialog id={id} ref={dialogRef} className="modal" onClick={handleBackdropClick}>
        <div className="modal-box">
          {title && <h3 className="text-lg font-bold mb-4">{title}</h3>}
          {children}
        </div>
        <form method="dialog" className="modal-backdrop">
          <button type="submit">close</button>
        </form>
      </dialog>
    );
  },
);

Modal.displayName = "Modal";
