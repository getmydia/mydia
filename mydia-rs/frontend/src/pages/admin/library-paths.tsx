import { useRef, useState, useCallback, useEffect } from "react";
import { useQuery, useMutation, useSubscription } from "urql";
import type {
  LibraryScanProgressSubscription,
} from "../../graphql/generated/graphql";
import {
  LibraryPathsDocument,
  CreateLibraryPathDocument,
  DeleteLibraryPathDocument,
  TriggerScanDocument,
  LibraryScanProgressDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Modal, type ModalHandle } from "../../components/modal";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { StatusPill } from "../../components/status-pill";
import { ScanProgress } from "../../components/scan-progress";
import { Alert } from "../../components/feedback";

type ScanStatus = "idle" | "starting" | "scanning" | "complete" | "failed";

function mapStageToStatus(stage: string): ScanStatus {
  switch (stage) {
    case "starting":
      return "starting";
    case "completed":
      return "complete";
    case "error":
      return "failed";
    case "creating_files":
    case "updating_files":
    case "deleting_files":
    case "scanning":
    default:
      return "scanning";
  }
}

export function LibraryPathsPage() {
  const [result, refetch] = useQuery({ query: LibraryPathsDocument });
  const [, createMutation] = useMutation(CreateLibraryPathDocument);
  const [, deleteMutation] = useMutation(DeleteLibraryPathDocument);
  const [, triggerScan] = useMutation(TriggerScanDocument);

  const modalRef = useRef<ModalHandle>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [scanning, setScanning] = useState<string | null>(null);

  const [path, setPath] = useState("");
  const [type_, setType] = useState("movies");
  const [monitored, setMonitored] = useState(true);
  const [scanInterval, setScanInterval] = useState("");

  // Accumulate scan progress per path ID
  const [scanProgress, setScanProgress] = useState<
    Record<string, { current?: number; total?: number; stage?: string; filesFound?: number; error?: string }>
  >({});

  useSubscription<
    LibraryScanProgressSubscription,
    { libraryScanProgress: LibraryScanProgressSubscription["libraryScanProgress"] }
  >(
    { query: LibraryScanProgressDocument },
    (_prev, event) => {
      const ev = event.libraryScanProgress;
      if (ev.pathId) {
        const key = ev.pathId;
        setScanProgress((prev) => ({
          ...prev,
          [key]: {
            current: ev.current ?? undefined,
            total: ev.total ?? undefined,
            stage: ev.stage,
            filesFound: ev.filesFound ?? undefined,
            error: ev.error ?? undefined,
          },
        }));
        // Clear progress when scan completes or errors
        if (ev.stage === "completed" || ev.stage === "error") {
          setTimeout(() => {
            setScanProgress((prev) => {
              const next = { ...prev };
              delete next[key];
              return next;
            });
          }, 3000);
        }
      }
      return event;
    },
  );

  // Refetch list when scan completes
  useEffect(() => {
    const hasCompleted = Object.values(scanProgress).some(
      (p) => p.stage === "completed",
    );
    if (hasCompleted) {
      refetch();
    }
  }, [scanProgress, refetch]);

  const data = result.data?.libraryPaths ?? [];
  const error = result.error;

  const handleCreate = useCallback(async () => {
    setFormError(null);
    setSaving(true);
    const res = await createMutation({
      input: {
        path,
        type: type_,
        monitored,
        scanInterval: scanInterval ? parseInt(scanInterval, 10) : null,
      },
    });
    setSaving(false);
    if (res.error) {
      setFormError(res.error.message);
    } else {
      modalRef.current?.close();
      setPath("");
      setType("movies");
      setMonitored(true);
      setScanInterval("");
      refetch();
    }
  }, [path, type_, monitored, scanInterval, createMutation, refetch]);

  const handleDelete = useCallback(
    async (id: string) => {
      await deleteMutation({ id });
      refetch();
    },
    [deleteMutation, refetch],
  );

  const handleScan = useCallback(
    async (id: string) => {
      setScanning(id);
      await triggerScan({ pathId: id });
      setScanning(null);
    },
    [triggerScan],
  );

  if (result.fetching && data.length === 0) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        title="Library Paths"
        subtitle="Manage directories that Mydia watches for media files"
        actions={
          <Button onClick={() => modalRef.current?.show()}>Add Path</Button>
        }
      />

      {error && (
        <Alert kind="error" title="Failed to load library paths">
          {error.message}
        </Alert>
      )}

      <Card>
        <Table
          columns={[
            {
              key: "path",
              header: "Path",
              render: (row) => (
                <span className="font-mono text-sm">{row.path}</span>
              ),
            },
            {
              key: "type",
              header: "Type",
              render: (row) => <StatusPill status={row.type} />,
            },
            {
              key: "monitored",
              header: "Monitored",
              render: (row) =>
                row.monitored ? (
                  <StatusPill status="active" label="Yes" />
                ) : (
                  <StatusPill status="inactive" label="No" />
                ),
            },
            {
              key: "scanInterval",
              header: "Scan Interval",
              render: (row) => (
                <span>{row.scanInterval ? `${row.scanInterval} min` : "--"}</span>
              ),
            },
            {
              key: "autoOrganize",
              header: "Auto Organize",
              render: (row) =>
                row.autoOrganize ? (
                  <StatusPill status="active" label="Yes" />
                ) : (
                  <StatusPill status="inactive" label="No" />
                ),
            },
            {
              key: "scanProgress",
              header: "Progress",
              render: (row) => {
                const progress = scanProgress[row.id];
                if (progress) {
                  const status = mapStageToStatus(progress.stage ?? "scanning");
                  return (
                    <ScanProgress
                      current={progress.current}
                      total={progress.total}
                      stage={progress.stage}
                      filesFound={progress.filesFound}
                      status={status}
                      error={progress.error}
                    />
                  );
                }
                return row.lastScanAt ? (
                  <span className="text-xs text-base-content/60">
                    Last: {new Date(row.lastScanAt).toLocaleString()}
                  </span>
                ) : (
                  <span className="text-xs text-base-content/40">--</span>
                );
              },
            },
            {
              key: "actions",
              header: "Actions",
              render: (row) => (
                <div className="flex gap-1">
                  <Button
                    size="sm"
                    variant="info"
                    loading={scanning === row.id}
                    onClick={() => handleScan(row.id)}
                  >
                    Scan
                  </Button>
                  <Button
                    size="sm"
                    variant="error"
                    onClick={() => handleDelete(row.id)}
                  >
                    Delete
                  </Button>
                </div>
              ),
            },
          ]}
          rows={data}
          keyExtractor={(row) => row.id}
          emptyMessage="No library paths configured."
        />
      </Card>

      <Modal ref={modalRef} title="Add Library Path" onClose={() => setFormError(null)}>
        <div className="flex flex-col gap-3">
          {formError && (
            <Alert kind="error">{formError}</Alert>
          )}
          <Input
            label="Path"
            placeholder="/media/tv"
            value={path}
            onChange={(e) => setPath(e.target.value)}
          />
          <div className="form-control w-full">
            <label className="label py-1">
              <span className="label-text">Type</span>
            </label>
            <select
              className="select select-bordered w-full"
              value={type_}
              onChange={(e) => setType(e.target.value)}
            >
              <option value="movies">Movies</option>
              <option value="series">Series</option>
              <option value="mixed">Mixed</option>
              <option value="music">Music</option>
              <option value="books">Books</option>
              <option value="adult">Adult</option>
            </select>
          </div>
          <label className="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              className="toggle toggle-primary"
              checked={monitored}
              onChange={(e) => setMonitored(e.target.checked)}
            />
            <span className="label-text">Monitored</span>
          </label>
          <Input
            label="Scan Interval (minutes)"
            placeholder="360"
            type="number"
            value={scanInterval}
            onChange={(e) => setScanInterval(e.target.value)}
          />
          <div className="flex justify-end gap-2 mt-2">
            <Button variant="ghost" onClick={() => modalRef.current?.close()}>
              Cancel
            </Button>
            <Button loading={saving} onClick={handleCreate}>
              Save
            </Button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
