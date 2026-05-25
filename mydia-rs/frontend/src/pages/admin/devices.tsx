import { useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  DevicesByUserDocument,
  RevokeDeviceDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Alert } from "../../components/feedback";
import { StatusPill } from "../../components/status-pill";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { pushToast } from "../../components/feedback";

export function DevicesPage() {
  const [userId, setUserId] = useState("");
  const [searchId, setSearchId] = useState("");

  const [result, refetch] = useQuery({
    query: DevicesByUserDocument,
    variables: { userId: searchId },
    pause: !searchId,
  });

  const [, revokeDevice] = useMutation(RevokeDeviceDocument);

  const devices = result.data?.devicesByUser ?? [];
  const error = result.error;

  const handleSearch = useCallback(() => {
    if (userId.trim()) {
      setSearchId(userId.trim());
    }
  }, [userId]);

  const handleRevoke = useCallback(
    async (id: string) => {
      const res = await revokeDevice({ id });
      if (res.error) {
        pushToast(res.error.message, { kind: "error" });
      } else {
        pushToast("Device revoked", { kind: "success" });
        refetch();
      }
    },
    [revokeDevice, refetch],
  );

  return (
    <div>
      <PageHeader
        title="Devices"
        subtitle="Manage user devices and remote access"
      />

      <Card className="mb-4">
        <div className="flex items-end gap-3">
          <Input
            label="User ID"
            placeholder="Enter a user UUID"
            value={userId}
            onChange={(e) => setUserId(e.target.value)}
            className="max-w-sm"
          />
          <Button onClick={handleSearch}>Search</Button>
        </div>
      </Card>

      {error && (
        <Alert kind="error" title="Failed to load devices">
          {error.message}
        </Alert>
      )}

      {searchId && (
        <Card>
          <Table
            columns={[
              {
                key: "name",
                header: "Device Name",
                render: (r) => <span className="text-sm font-medium">{r.deviceName}</span>,
              },
              {
                key: "platform",
                header: "Platform",
                render: (r) => <span className="badge badge-outline">{r.platform}</span>,
              },
              {
                key: "status",
                header: "Status",
                render: (r) =>
                  r.isRevoked ? (
                    <StatusPill status="revoked" />
                  ) : (
                    <StatusPill status="active" />
                  ),
              },
              {
                key: "lastSeen",
                header: "Last Seen",
                render: (r) => (
                  <span className="text-xs">
                    {r.lastSeenAt
                      ? new Date(r.lastSeenAt).toLocaleString()
                      : "Never"}
                  </span>
                ),
              },
              {
                key: "created",
                header: "Created",
                render: (r) => (
                  <span className="text-xs">
                    {new Date(r.createdAt).toLocaleString()}
                  </span>
                ),
              },
              {
                key: "actions",
                header: "Actions",
                render: (r) =>
                  !r.isRevoked ? (
                    <Button
                      size="sm"
                      variant="error"
                      onClick={() => handleRevoke(r.id)}
                    >
                      Revoke
                    </Button>
                  ) : null,
              },
            ]}
            rows={devices}
            keyExtractor={(r) => r.id}
            emptyMessage="No devices found for this user."
          />
        </Card>
      )}
    </div>
  );
}
