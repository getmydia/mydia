import type { InputHTMLAttributes } from "react";

interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string;
  error?: string;
  hint?: string;
}

export function Input({
  label,
  error,
  hint,
  id,
  className = "",
  ...rest
}: InputProps) {
  const inputId = id ?? label?.toLowerCase().replace(/\s+/g, "-");

  return (
    <div className="form-control w-full">
      {label && (
        <label htmlFor={inputId} className="label py-1">
          <span className="label-text">{label}</span>
        </label>
      )}
      <input
        id={inputId}
        className={[
          "input input-bordered w-full",
          error ? "input-error" : "",
          className,
        ]
          .filter(Boolean)
          .join(" ")}
        {...rest}
      />
      {hint && !error && (
        <label className="label py-1">
          <span className="label-text-alt text-base-content/60">{hint}</span>
        </label>
      )}
      {error && (
        <label className="label py-1">
          <span className="label-text-alt text-error">{error}</span>
        </label>
      )}
    </div>
  );
}
