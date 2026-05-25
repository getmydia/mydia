interface FilterOption {
  value: string;
  label: string;
}

interface FilterBarProps {
  current: string;
  options: FilterOption[];
  onChange: (value: string) => void;
}

export function FilterBar({ current, options, onChange }: FilterBarProps) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      {options.map((opt) => {
        const isActive = opt.value === current;
        return (
          <button
            key={opt.value}
            type="button"
            className={[
              "btn btn-xs",
              isActive ? "btn-primary" : "btn-ghost",
            ].join(" ")}
            onClick={() => onChange(opt.value)}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}
