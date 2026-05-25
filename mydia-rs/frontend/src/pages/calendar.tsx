import { useState, useMemo, useCallback } from "react";
import { useQuery } from "urql";
import { CalendarDocument } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { CalendarGrid } from "../components/calendar-grid";

function getMonthRange(date: Date): { start: Date; end: Date } {
  const start = new Date(date.getFullYear(), date.getMonth(), 1);
  const end = new Date(date.getFullYear(), date.getMonth() + 1, 0, 23, 59, 59);
  return { start, end };
}

export function CalendarPage() {
  const [currentDate, setCurrentDate] = useState(new Date());

  const { start, end } = useMemo(() => getMonthRange(currentDate), [currentDate]);

  const [{ data, fetching, error }] = useQuery({
    query: CalendarDocument,
    variables: {
      start: start.toISOString(),
      end: end.toISOString(),
    },
  });

  const entries = data?.calendar ?? [];

  const goToPrevMonth = useCallback(() => {
    setCurrentDate(
      (d) => new Date(d.getFullYear(), d.getMonth() - 1, 1),
    );
  }, []);

  const goToNextMonth = useCallback(() => {
    setCurrentDate(
      (d) => new Date(d.getFullYear(), d.getMonth() + 1, 1),
    );
  }, []);

  const goToToday = useCallback(() => {
    setCurrentDate(new Date());
  }, []);

  const monthLabel = currentDate.toLocaleString("default", {
    month: "long",
    year: "numeric",
  });

  return (
    <div>
      <PageHeader
        title="Calendar"
        subtitle="Upcoming and recently aired episodes"
        actions={
          <div className="flex items-center gap-2">
            <button className="btn btn-sm btn-ghost" onClick={goToPrevMonth}>
              &larr;
            </button>
            <button className="btn btn-sm btn-ghost" onClick={goToToday}>
              Today
            </button>
            <button className="btn btn-sm btn-ghost" onClick={goToNextMonth}>
              &rarr;
            </button>
            <span className="text-sm font-medium min-w-32 text-center">
              {monthLabel}
            </span>
          </div>
        }
      />

      {error && (
        <div className="alert alert-error mb-4">
          Failed to load calendar data.
        </div>
      )}

      {fetching ? (
        <div className="flex justify-center py-16">
          <span className="loading loading-spinner loading-lg" />
        </div>
      ) : (
        <CalendarGrid
          year={currentDate.getFullYear()}
          month={currentDate.getMonth()}
          entries={entries.map((e) => ({
            id: e.id,
            title: e.episodeTitle ?? `Episode ${e.episodeNumber}`,
            showTitle: e.showTitle,
            seasonNumber: e.seasonNumber,
            episodeNumber: e.episodeNumber,
            airDate: e.airDate ?? "",
            monitored: e.monitored,
            hasFile: e.hasFile,
            showId: e.showId,
          }))}
        />
      )}
    </div>
  );
}
