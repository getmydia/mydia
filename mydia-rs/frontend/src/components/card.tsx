import type { ReactNode } from "react";

interface CardProps {
  title?: string;
  subtitle?: string;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
}

export function Card({
  title,
  subtitle,
  actions,
  children,
  className = "",
}: CardProps) {
  return (
    <div className={["card bg-base-100 shadow-xl", className].join(" ")}>
      <div className="card-body">
        {(title ?? actions) && (
          <div className="flex items-start justify-between gap-2">
            <div>
              {title && <h2 className="card-title">{title}</h2>}
              {subtitle && (
                <p className="text-sm text-base-content/70 mt-1">{subtitle}</p>
              )}
            </div>
            {actions && <div className="flex items-center gap-2">{actions}</div>}
          </div>
        )}
        {children}
      </div>
    </div>
  );
}
