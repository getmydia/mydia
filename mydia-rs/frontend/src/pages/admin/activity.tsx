import { useState } from "react";
import { useQuery } from "urql";
import { AdminActivityDocument } from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Alert } from "../../components/feedback";
import { StatusPill } from "../../components/status-pill";

const CATEGORY_OPTIONS = [
  { value: "", label: "All Categories" },
  { value: "media", label: "Media" },
  { value: "system", label: "System" },
  { value: "auth", label: "Auth" },
  { value: "download", label: "Download" },
];

const SEVERITY_OPTIONS = [
  { value: "", label: "All Severities" },
  { value: "info", label: "Info" },
  { value: "warning", label: "Warning" },
  { value: "error", label: "Error" },
];

function ActivityEventRow({
  event,
}: {
  event: {
    id: string;
    category: string;
    type: string;
    severity: string;
    resourceType?: string | null;
    resourceId?: string | null;
    metadata?: unknown;
    insertedAt: string;
  };
}) {
  const icon = event.severity === "error" ? "✕" : event.severity === "warning" ? "⚠" : "✓";

  return (
    <div className="flex items-center gap-3 py-2 border-b border-base-200 last:border-b-0">
      <div
        className={[
          "w-8 h-8 rounded-full flex items-center justify-center text-sm flex-shrink-0",
          event.severity === "error"
            ? "bg-error/20 text-error"
            : event.severity === "warning"
              ? "bg-warning/20 text-warning"
              : "bg-info/20 text-info",
        ].join(" ")}
      >
        {icon}
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <StatusPill status={event.category} />
          <span className="text-sm font-medium">{event.type}</span>
          <StatusPill status={event.severity} />
        </div>
        {event.resourceType && (
          <div className="text-xs text-base-content/60 mt-1">
            {event.resourceType}
            {event.resourceId ? `/${event.resourceId}` : ""}
          </div>
        )}
      </div>
      <div className="text-xs text-base-content/50 flex-shrink-0">
        {new Date(event.insertedAt).toLocaleString()}
      </div>
    </div>
  );
}

export function ActivityPage() {
  const [category, setCategory] = useState("");
  const [severity, setSeverity] = useState("");

  const filter = {
    category: category || null,
    severity: severity || null,
    resourceType: null,
  };

  const [result] = useQuery({
    query: AdminActivityDocument,
    variables: { filter, limit: 100 },
    pause: false,
  });

  const events = result.data?.activity ?? [];
  const error = result.error;

  if (result.fetching && events.length === 0) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        title="Activity Log"
        subtitle="System-wide activity and event history"
      />

      {error && (
        <Alert kind="error" title="Failed to load activity">
          {error.message}
        </Alert>
      )}

      <div className="flex items-center gap-3 mb-4">
        <select
          className="select select-bordered select-sm"
          value={category}
          onChange={(e) => setCategory(e.target.value)}
        >
          {CATEGORY_OPTIONS.map((opt) => (
            <option key={opt.value} value={opt.value}>
              {opt.label}
            </option>
          ))}
        </select>
        <select
          className="select select-bordered select-sm"
          value={severity}
          onChange={(e) => setSeverity(e.target.value)}
        >
          {SEVERITY_OPTIONS.map((opt) => (
            <option key={opt.value} value={opt.value}>
              {opt.label}
            </option>
          ))}
        </select>
      </div>

      <Card>
        {events.length === 0 ? (
          <div className="text-center text-base-content/50 py-8">
            No activity events found.
          </div>
        ) : (
          events.map((event) => (
            <ActivityEventRow key={event.id} event={event} />
          ))
        )}
      </Card>
    </div>
  );
}
