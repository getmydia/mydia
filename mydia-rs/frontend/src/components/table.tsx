import type { ReactNode } from "react";

interface Column<T> {
  key: string;
  header: string;
  render: (row: T, index: number) => ReactNode;
  className?: string;
}

interface TableProps<T> {
  columns: Column<T>[];
  rows: T[];
  keyExtractor: (row: T, index: number) => string;
  emptyMessage?: string;
  className?: string;
}

export function Table<T>({
  columns,
  rows,
  keyExtractor,
  emptyMessage = "No items found.",
  className = "",
}: TableProps<T>) {
  return (
    <div className={["overflow-x-auto", className].join(" ")}>
      <table className="table table-zebra">
        <thead>
          <tr>
            {columns.map((col) => (
              <th key={col.key} className={col.className}>
                {col.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td colSpan={columns.length} className="text-center text-base-content/50 py-8">
                {emptyMessage}
              </td>
            </tr>
          ) : (
            rows.map((row, i) => (
              <tr key={keyExtractor(row, i)}>
                {columns.map((col) => (
                  <td key={col.key} className={col.className}>
                    {col.render(row, i)}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}
