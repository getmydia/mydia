import { useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  AdminTranscodesDocument,
  CancelTranscodeDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Alert } from "../../components/feedback";
import { StatusPill } from "../../components/status-pill";
import { Button } from "../../components/button";
import { pushToast } from "../../components/feedback";

export function TranscodesPage() {
  const [result, refetch] = useQuery({ query: AdminTranscodesDocument });
  const [, cancelTranscode] = useMutation(CancelTranscodeDocument);

  const transcodes = result.data?.transcodes ?? [];
  const error = result.error;

  const handleCancel = useCallback(
    async (id: string) => {
      const res = await cancelTranscode({ id });
      if (res.error) {
        pushToast(res.error.message, { kind: "error" });
      } else {
        pushToast("Transcode cancelled", { kind: "success" });
        refetch();
      }
    },
    [cancelTranscode, refetch],
  );

  if (result.fetching && transcodes.length === 0) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        title="Transcodes"
        subtitle="Media transcoding jobs and progress"
      />

      {error && (
        <Alert kind="error" title="Failed to load transcodes">
          {error.message}
        </Alert>
      )}

      <Card>
        <Table
          columns={[
            {
              key: "status",
              header: "Status",
              render: (r) => <StatusPill status={r.status} />,
            },
            {
              key: "resolution",
              header: "Resolution",
              render: (r) => <span className="badge badge-outline">{r.resolution}</span>,
            },
            {
              key: "progress",
              header: "Progress",
              render: (r) => (
                <div className="flex items-center gap-2">
                  <progress
                    className="progress progress-primary w-24"
                    value={r.progress ?? 0}
                    max={1}
                  />
                  <span className="text-xs">
                    {r.progress != null ? `${Math.round(r.progress * 100)}%` : "--"}
                  </span>
                </div>
              ),
            },
            {
              key: "type",
              header: "Type",
              render: (r) => <span className="badge">{r.type}</span>,
            },
            {
              key: "error",
              header: "Error",
              render: (r) => (
                <span className="text-xs text-error">{r.error ?? "--"}</span>
              ),
            },
            {
              key: "inserted",
              header: "Created",
              render: (r) => (
                <span className="text-xs">
                  {new Date(r.insertedAt).toLocaleString()}
                </span>
              ),
            },
            {
              key: "actions",
              header: "Actions",
              render: (r) =>
                r.status !== "completed" && r.status !== "cancelled" ? (
                  <Button
                    size="sm"
                    variant="warning"
                    onClick={() => handleCancel(r.id)}
                  >
                    Cancel
                  </Button>
                ) : null,
            },
          ]}
          rows={transcodes}
          keyExtractor={(r) => r.id}
          emptyMessage="No transcode jobs found."
        />
      </Card>
    </div>
  );
}
