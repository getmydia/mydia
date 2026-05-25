import { type ReactNode } from "react";

interface NestedFormArrayProps<T> {
  idPrefix: string;
  items: T[];
  renderItem: (item: T, index: number) => ReactNode;
  onAdd: () => void;
  onRemove: (index: number) => void;
  onMoveUp: (index: number) => void;
  onMoveDown: (index: number) => void;
  addLabel?: string;
  help?: string;
  error?: string;
  emptyMessage?: string;
}

export function NestedFormArray<T>({
  idPrefix,
  items,
  renderItem,
  onAdd,
  onRemove,
  onMoveUp,
  onMoveDown,
  addLabel = "Add item",
  help,
  error,
  emptyMessage = "No items yet.",
}: NestedFormArrayProps<T>) {
  const isEmpty = items.length === 0;
  const lastIndex = items.length - 1;

  return (
    <div id={idPrefix} className="flex flex-col gap-3">
      {help && <p className="text-xs text-base-content/60">{help}</p>}

      {isEmpty ? (
        <div className="text-sm text-base-content/60 py-4 text-center border border-dashed border-base-content/20 rounded-box">
          {emptyMessage}
        </div>
      ) : (
        <ul className="flex flex-col gap-2">
          {items.map((item, index) => (
            <li
              key={`${idPrefix}-${index}`}
              className="flex items-start gap-2 p-2 bg-base-200 rounded-box"
            >
              <div className="flex-1 min-w-0">{renderItem(item, index)}</div>
              <div className="flex flex-col gap-1 shrink-0">
                <button
                  type="button"
                  className="btn btn-xs btn-ghost"
                  disabled={index === 0}
                  title="Move up"
                  onClick={() => onMoveUp(index)}
                >
                  ↑
                </button>
                <button
                  type="button"
                  className="btn btn-xs btn-ghost"
                  disabled={index >= lastIndex}
                  title="Move down"
                  onClick={() => onMoveDown(index)}
                >
                  ↓
                </button>
                <button
                  type="button"
                  className="btn btn-xs btn-ghost text-error"
                  title="Remove"
                  onClick={() => onRemove(index)}
                >
                  ×
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {error && <p className="text-sm text-error">{error}</p>}

      <button type="button" className="btn btn-sm btn-outline" onClick={onAdd}>
        + {addLabel}
      </button>
    </div>
  );
}
