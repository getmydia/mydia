import { useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  PairedDevicesDocument,
  RemoteAccessStatusQueryDocument,
  RevokePairedDeviceDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Alert } from "../../components/feedback";
import { StatusPill } from "../../components/status-pill";
import { Button } from "../../components/button";
import { pushToast } from "../../components/feedback";

export function RemoteAccessPage() {
  const [devicesResult, refetchDevices] = useQuery({
    query: PairedDevicesDocument,
  });
  const [statusResult] = useQuery({
    query: RemoteAccessStatusQueryDocument,
  });
  const [, revokePaired] = useMutation(RevokePairedDeviceDocument);

  const devices = devicesResult.data?.pairedDevices ?? [];
  const status = statusResult.data?.remoteAccessStatus;
  const error = devicesResult.error ?? statusResult.error;

  const handleRevoke = useCallback(
    async (id: string) => {
      const res = await revokePaired({ id });
      if (res.error) {
        pushToast(res.error.message, { kind: "error" });
      } else {
        pushToast("Device revoked", { kind: "success" });
        refetchDevices();
      }
    },
    [revokePaired, refetchDevices],
  );

  if (devicesResult.fetching && devices.length === 0) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        title="Remote Access"
        subtitle="Manage paired devices and remote access configuration"
      />

      {error && (
        <Alert kind="error" title="Failed to load remote access data">
          {error.message}
        </Alert>
      )}

      {status && (
        <Card className="mb-4">
          <div className="flex items-center gap-6">
            <div>
              <span className="text-sm text-base-content/70">Status</span>
              <div className="mt-1">
                {status.enabled ? (
                  <StatusPill status="active" label="Enabled" />
                ) : (
                  <StatusPill status="inactive" label="Disabled" />
                )}
              </div>
            </div>
            <div>
              <span className="text-sm text-base-content/70">Connected Peers</span>
              <div className="mt-1">
                <span className="badge badge-primary">{status.connectedPeers}</span>
              </div>
            </div>
            {status.endpointAddr && (
              <div>
                <span className="text-sm text-base-content/70">Endpoint</span>
                <div className="mt-1">
                  <span className="font-mono text-sm">{status.endpointAddr}</span>
                </div>
              </div>
            )}
          </div>
        </Card>
      )}

      <Card>
        <h3 className="text-lg font-semibold mb-3">Paired Devices</h3>
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
          emptyMessage="No paired devices."
        />
      </Card>
    </div>
  );
}
