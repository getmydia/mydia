import { useMemo } from "react";

interface CalendarEntryData {
  id: string;
  title: string;
  showTitle: string;
  seasonNumber: number;
  episodeNumber: number;
  airDate: string;
  monitored: boolean;
  hasFile: boolean;
  showId?: string;
}

interface CalendarGridProps {
  year: number;
  month: number;
  entries: CalendarEntryData[];
}

function getDaysInMonth(year: number, month: number): number {
  return new Date(year, month + 1, 0).getDate();
}

function getFirstDayOfWeek(year: number, month: number): number {
  return new Date(year, month, 1).getDay();
}

const DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

export function CalendarGrid({ year, month, entries }: CalendarGridProps) {
  const daysInMonth = getDaysInMonth(year, month);
  const firstDayOfWeek = getFirstDayOfWeek(year, month);

  const entriesByDay = useMemo(() => {
    const map = new Map<number, CalendarEntryData[]>();
    for (const entry of entries) {
      if (!entry.airDate) continue;
      const day = new Date(entry.airDate).getDate();
      const entryMonth = new Date(entry.airDate).getMonth();
      const entryYear = new Date(entry.airDate).getFullYear();
      if (entryMonth !== month || entryYear !== year) continue;
      if (!map.has(day)) map.set(day, []);
      map.get(day)!.push(entry);
    }
    return map;
  }, [entries, year, month]);

  const cells: (number | null)[] = [];
  for (let i = 0; i < firstDayOfWeek; i++) {
    cells.push(null);
  }
  for (let d = 1; d <= daysInMonth; d++) {
    cells.push(d);
  }

  const today = new Date();
  const isCurrentMonth =
    today.getFullYear() === year && today.getMonth() === month;
  const todayDate = today.getDate();

  return (
    <div className="card bg-base-100 shadow">
      <div className="card-body p-2 sm:p-4">
        <div className="grid grid-cols-7 gap-px bg-base-300 rounded-lg overflow-hidden">
          {DAY_NAMES.map((name) => (
            <div
              key={name}
              className="bg-base-200 p-2 text-center text-xs font-semibold text-base-content/70 uppercase"
            >
              {name}
            </div>
          ))}
          {cells.map((day, idx) => (
            <div
              key={idx}
              className={[
                "bg-base-100 min-h-[80px] sm:min-h-[100px] p-1",
                isCurrentMonth && day === todayDate
                  ? "ring-2 ring-primary ring-inset"
                  : "",
              ]
                .filter(Boolean)
                .join(" ")}
            >
              {day != null && (
                <>
                  <span className="text-xs font-medium text-base-content/70">
                    {day}
                  </span>
                  <div className="mt-0.5 space-y-0.5">
                    {(entriesByDay.get(day) ?? []).map((entry) => (
                      <a
                        key={entry.id}
                        href={`/media/${entry.showId ?? entry.id}`}
                        className="block text-[10px] leading-tight truncate px-1 py-0.5 rounded hover:bg-base-200 transition-colors"
                        title={`${entry.showTitle} S${String(entry.seasonNumber).padStart(2, "0")}E${String(entry.episodeNumber).padStart(2, "0")}: ${entry.title}`}
                      >
                        <span
                          className={[
                            entry.hasFile
                              ? "text-success"
                              : entry.monitored
                                ? "text-warning"
                                : "text-base-content/50",
                          ].join(" ")}
                        >
                          {!entry.hasFile && !entry.monitored && "\u25CB "}
                          {!entry.hasFile && entry.monitored && "\u25D4 "}
                          {entry.hasFile && "\u25CF "}
                        </span>
                        <span className="font-medium">
                          {entry.showTitle}
                        </span>
                      </a>
                    ))}
                  </div>
                </>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
