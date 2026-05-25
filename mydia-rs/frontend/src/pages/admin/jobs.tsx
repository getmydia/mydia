import { useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  WorkerSummaryDocument,
  RecentJobEventsDocument,
  TriggerJobDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Alert } from "../../components/feedback";
import { StatusPill } from "../../components/status-pill";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { pushToast } from "../../components/feedback";

const JOB_LIMIT = 50;

export function JobsPage() {
  const [workerResult, refetchWorker] = useQuery({
    query: WorkerSummaryDocument,
  });
  const [eventsResult, refetchEvents] = useQuery({
    query: RecentJobEventsDocument,
    variables: { limit: JOB_LIMIT },
  });
  const [, triggerJob] = useMutation(TriggerJobDocument);

  const [jobName, setJobName] = useState("");
  const [triggering, setTriggering] = useState(false);
  const [triggerError, setTriggerError] = useState<string | null>(null);

  const workers = workerResult.data?.workerSummary ?? [];
  const events = eventsResult.data?.recentJobEvents ?? [];
  const error = workerResult.error ?? eventsResult.error;

  const handleTrigger = useCallback(async () => {
    if (!jobName.trim()) return;
    setTriggerError(null);
    setTriggering(true);
    const res = await triggerJob({ name: jobName.trim() });
    setTriggering(false);
    if (res.error) {
      setTriggerError(res.error.message);
    } else {
      setJobName("");
      pushToast(`Job "${jobName}" triggered`, { kind: "success" });
      refetchWorker();
      refetchEvents();
    }
  }, [jobName, triggerJob, refetchWorker, refetchEvents]);

  return (
    <div>
      <PageHeader
        title="Jobs & Workers"
        subtitle="Background job processing status and controls"
      />

      {error && (
        <Alert kind="error" title="Failed to load jobs">
          {error.message}
        </Alert>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4 mb-6">
        <Card className="lg:col-span-1">
          <h3 className="text-lg font-semibold mb-3">Trigger Job</h3>
          <div className="flex flex-col gap-2">
            {triggerError && <Alert kind="error">{triggerError}</Alert>}
            <Input
              label="Job Name"
              placeholder="e.g. MediaImportWorker"
              value={jobName}
              onChange={(e) => setJobName(e.target.value)}
            />
            <Button loading={triggering} onClick={handleTrigger}>
              Trigger
            </Button>
          </div>
        </Card>

        <Card className="lg:col-span-2">
          <Table
            columns={[
              { key: "queue", header: "Queue", render: (r) => <span className="font-mono text-sm">{r.queue}</span> },
              { key: "worker", header: "Worker", render: (r) => <span className="font-mono text-sm">{r.worker}</span> },
              { key: "count", header: "Count", render: (r) => <span className="badge">{r.count}</span> },
              { key: "priority", header: "Max Priority", render: (r) => <span>{r.maxPriority ?? "--"}</span> },
              {
                key: "oldest",
                header: "Oldest Scheduled",
                render: (r) => (
                  <span className="text-xs">
                    {r.oldestScheduledAt
                      ? new Date(r.oldestScheduledAt).toLocaleString()
                      : "--"}
                  </span>
                ),
              },
            ]}
            rows={workers}
            keyExtractor={(r) => `${r.queue}:${r.worker}`}
            emptyMessage="No active workers."
          />
        </Card>
      </div>

      <Card>
        <h3 className="text-lg font-semibold mb-3">
          Recent Job Events
          <Button
            size="xs"
            variant="ghost"
            className="ml-2"
            onClick={() => {
              refetchWorker();
              refetchEvents();
            }}
          >
            Refresh
          </Button>
        </h3>
        <Table
          columns={[
            {
              key: "state",
              header: "State",
              render: (r) => <StatusPill status={r.state} />,
            },
            { key: "worker", header: "Worker", render: (r) => <span className="font-mono text-sm">{r.worker}</span> },
            { key: "queue", header: "Queue", render: (r) => <span className="font-mono text-xs">{r.queue}</span> },
            {
              key: "attempts",
              header: "Attempts",
              render: (r) => (
                <span>
                  {r.attempt}/{r.maxAttempts}
                </span>
              ),
            },
            {
              key: "scheduled",
              header: "Scheduled At",
              render: (r) => (
                <span className="text-xs">{new Date(r.scheduledAt).toLocaleString()}</span>
              ),
            },
            {
              key: "completed",
              header: "Completed At",
              render: (r) => (
                <span className="text-xs">
                  {r.completedAt ? new Date(r.completedAt).toLocaleString() : "--"}
                </span>
              ),
            },
          ]}
          rows={events}
          keyExtractor={(r) => String(r.id)}
          emptyMessage="No recent job events."
        />
      </Card>
    </div>
  );
}
