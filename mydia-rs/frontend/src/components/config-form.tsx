import type { ReactNode } from "react";

type ConfigSource = "default" | "env" | "database";

interface ConfigSectionProps {
  title: string;
  description?: string;
  id?: string;
  actions?: ReactNode;
  children: ReactNode;
}

const sourceBadgeClass = (source: ConfigSource): string => {
  switch (source) {
    case "default":
      return "badge-ghost";
    case "env":
      return "badge-info";
    case "database":
      return "badge-primary";
  }
};

const sourceLabel = (source: ConfigSource): string => source;

export function ConfigSection({
  title,
  description,
  id,
  actions,
  children,
}: ConfigSectionProps) {
  return (
    <section id={id} className="card bg-base-100 shadow mb-6">
      <div className="card-body">
        <header className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between mb-4">
          <div>
            <h2 className="card-title text-lg">{title}</h2>
            {description && (
              <p className="text-sm text-base-content/70 mt-1">{description}</p>
            )}
          </div>
          {actions && <div className="flex items-center gap-2">{actions}</div>}
        </header>
        {children}
      </div>
    </section>
  );
}

interface ConfigRowProps {
  label: string;
  description?: string;
  source?: ConfigSource;
  children: ReactNode;
}

export function ConfigRow({
  label,
  description,
  source,
  children,
}: ConfigRowProps) {
  return (
    <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 py-3 border-b border-base-content/10 last:border-b-0">
      <div className="sm:col-span-1">
        <div className="flex items-center gap-2">
          <label className="text-sm font-medium">{label}</label>
          {source && (
            <span
              className={["badge badge-xs", sourceBadgeClass(source)].join(
                " ",
              )}
            >
              {sourceLabel(source)}
            </span>
          )}
        </div>
        {description && (
          <p className="text-xs text-base-content/60 mt-1">{description}</p>
        )}
      </div>
      <div className="sm:col-span-2">{children}</div>
    </div>
  );
}

interface StatRowProps {
  label: string;
  value: string;
  hint?: string;
}

export function StatRow({ label, value, hint }: StatRowProps) {
  return (
    <div className="grid grid-cols-2 gap-3 py-2 text-sm border-b border-base-content/10 last:border-b-0">
      <div className="text-base-content/70">{label}</div>
      <div className="font-mono text-right">
        {value}
        {hint && (
          <span className="ml-2 text-xs text-base-content/60">{hint}</span>
        )}
      </div>
    </div>
  );
}
