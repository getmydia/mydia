import { useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  AdminRequestsDocument,
  ApproveRequestDocument,
  RejectRequestDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Alert } from "../../components/feedback";
import { StatusPill } from "../../components/status-pill";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { pushToast } from "../../components/feedback";

const STATUS_OPTIONS = [
  { value: "", label: "All" },
  { value: "pending", label: "Pending" },
  { value: "approved", label: "Approved" },
  { value: "rejected", label: "Rejected" },
];

export function RequestsPage() {
  const [statusFilter, setStatusFilter] = useState("");

  const [result, refetch] = useQuery({
    query: AdminRequestsDocument,
    variables: { status: statusFilter || null },
    pause: false,
  });

  const [, approveRequest] = useMutation(ApproveRequestDocument);
  const [, rejectRequest] = useMutation(RejectRequestDocument);

  const [notes, setNotes] = useState<Record<string, string>>({});
  const [actionError, setActionError] = useState<string | null>(null);

  const requests = result.data?.adminRequests ?? [];
  const error = result.error;

  const handleApprove = useCallback(
    async (id: string) => {
      setActionError(null);
      const res = await approveRequest({
        id,
        notes: notes[id] || null,
      });
      if (res.error) {
        setActionError(res.error.message);
      } else {
        pushToast("Request approved", { kind: "success" });
        setNotes((prev) => {
          const next = { ...prev };
          delete next[id];
          return next;
        });
        refetch();
      }
    },
    [notes, approveRequest, refetch],
  );

  const handleReject = useCallback(
    async (id: string) => {
      setActionError(null);
      const res = await rejectRequest({
        id,
        notes: notes[id] || null,
      });
      if (res.error) {
        setActionError(res.error.message);
      } else {
        pushToast("Request rejected", { kind: "success" });
        setNotes((prev) => {
          const next = { ...prev };
          delete next[id];
          return next;
        });
        refetch();
      }
    },
    [notes, rejectRequest, refetch],
  );

  if (result.fetching && requests.length === 0) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        title="Media Requests"
        subtitle="Review and manage user media requests"
      />

      {error && (
        <Alert kind="error" title="Failed to load requests">
          {error.message}
        </Alert>
      )}

      {actionError && (
        <Alert kind="error" title="Action failed">
          {actionError}
        </Alert>
      )}

      <div className="flex items-center gap-3 mb-4">
        <label className="label py-1">
          <span className="label-text">Status</span>
        </label>
        <select
          className="select select-bordered select-sm"
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
        >
          {STATUS_OPTIONS.map((opt) => (
            <option key={opt.value} value={opt.value}>
              {opt.label}
            </option>
          ))}
        </select>
      </div>

      <Card>
        <Table
          columns={[
            {
              key: "title",
              header: "Title",
              render: (r) => <span className="text-sm font-medium">{r.title}</span>,
            },
            {
              key: "type",
              header: "Type",
              render: (r) => <span className="badge">{r.mediaType}</span>,
            },
            {
              key: "status",
              header: "Status",
              render: (r) => <StatusPill status={r.status} />,
            },
            {
              key: "year",
              header: "Year",
              render: (r) => <span className="text-xs">{r.year ?? "--"}</span>,
            },
            {
              key: "requesterNotes",
              header: "Notes",
              render: (r) => (
                <span className="text-xs max-w-[200px] truncate block">
                  {r.requesterNotes ?? "--"}
                </span>
              ),
            },
            {
              key: "inserted",
              header: "Requested",
              render: (r) => (
                <span className="text-xs">
                  {new Date(r.insertedAt).toLocaleString()}
                </span>
              ),
            },
            {
              key: "notes",
              header: "Admin Notes",
              render: (r) =>
                r.status === "pending" ? (
                  <Input
                    className="input-xs w-32"
                    placeholder="Notes..."
                    value={notes[r.id] ?? ""}
                    onChange={(e) =>
                      setNotes((prev) => ({ ...prev, [r.id]: e.target.value }))
                    }
                  />
                ) : (
                  <span className="text-xs text-base-content/60">
                    {r.adminNotes ?? r.rejectionReason ?? "--"}
                  </span>
                ),
            },
            {
              key: "actions",
              header: "Actions",
              render: (r) =>
                r.status === "pending" ? (
                  <div className="flex gap-1">
                    <Button
                      size="xs"
                      variant="success"
                      onClick={() => handleApprove(r.id)}
                    >
                      Approve
                    </Button>
                    <Button
                      size="xs"
                      variant="error"
                      onClick={() => handleReject(r.id)}
                    >
                      Reject
                    </Button>
                  </div>
                ) : null,
            },
          ]}
          rows={requests}
          keyExtractor={(r) => r.id}
          emptyMessage="No requests found."
        />
      </Card>
    </div>
  );
}
