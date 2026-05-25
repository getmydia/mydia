import { useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  AdminDownloadsDocument,
  CancelDownloadDocument,
  ManuallyMatchDownloadDocument,
} from "../../graphql/generated/graphql";
import type { DownloadFilter } from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Alert } from "../../components/feedback";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { Modal, type ModalHandle } from "../../components/modal";
import { pushToast } from "../../components/feedback";
import { useRef } from "react";

type Tab = "queue" | "completed" | "issues";

const TAB_FILTER: Record<Tab, DownloadFilter> = {
  queue: "queue",
  completed: "completed",
  issues: "issues",
};

export function DownloadsPage() {
  const [tab, setTab] = useState<Tab>("queue");
  const filter = TAB_FILTER[tab];

  const [result, refetch] = useQuery({
    query: AdminDownloadsDocument,
    variables: { filter },
    pause: false,
  });

  const [, cancelDownload] = useMutation(CancelDownloadDocument);
  const [, manuallyMatch] = useMutation(ManuallyMatchDownloadDocument);

  const modalRef = useRef<ModalHandle>(null);
  const [matchId, setMatchId] = useState<string | null>(null);
  const [mediaIdInput, setMediaIdInput] = useState("");
  const [matchError, setMatchError] = useState<string | null>(null);
  const [matching, setMatching] = useState(false);

  const downloads = result.data?.downloads ?? [];
  const error = result.error;

  const handleCancel = useCallback(
    async (id: string) => {
      const res = await cancelDownload({ id });
      if (res.error) {
        pushToast(res.error.message, { kind: "error" });
      } else {
        pushToast("Download cancelled", { kind: "success" });
        refetch();
      }
    },
    [cancelDownload, refetch],
  );

  const handleMatchOpen = useCallback((id: string) => {
    setMatchId(id);
    setMediaIdInput("");
    setMatchError(null);
    modalRef.current?.show();
  }, []);

  const handleMatch = useCallback(async () => {
    if (!matchId || !mediaIdInput.trim()) return;
    setMatchError(null);
    setMatching(true);
    const res = await manuallyMatch({
      id: matchId,
      mediaId: mediaIdInput.trim(),
    });
    setMatching(false);
    if (res.error) {
      setMatchError(res.error.message);
    } else {
      pushToast("Download matched", { kind: "success" });
      modalRef.current?.close();
      refetch();
    }
  }, [matchId, mediaIdInput, manuallyMatch, refetch]);

  return (
    <div>
      <PageHeader
        title="Downloads"
        subtitle="Monitor and manage download activity"
      />

      {error && (
        <Alert kind="error" title="Failed to load downloads">
          {error.message}
        </Alert>
      )}

      <div className="tabs tabs-box mb-4">
        {(["queue", "completed", "issues"] as Tab[]).map((t) => (
          <a
            key={t}
            className={["tab tab-bordered", tab === t ? "tab-active" : ""].join(" ")}
            onClick={() => setTab(t)}
          >
            {t.charAt(0).toUpperCase() + t.slice(1)}
          </a>
        ))}
      </div>

      <Card>
        <Table
          columns={[
            { key: "title", header: "Title", render: (r) => <span className="text-sm">{r.title}</span> },
            {
              key: "matchStatus",
              header: "Match",
              render: (r) => (
                <span className="text-xs">{r.matchStatus ?? "unmatched"}</span>
              ),
            },
            {
              key: "client",
              header: "Client",
              render: (r) => <span className="badge badge-outline">{r.downloadClient ?? "--"}</span>,
            },
            {
              key: "indexer",
              header: "Indexer",
              render: (r) => <span className="text-xs">{r.indexer ?? "--"}</span>,
            },
            {
              key: "size",
              header: "Size",
              render: (r) => (
                <span className="text-xs">
                  {r.bytesPulled != null
                    ? `${(r.bytesPulled / 1024 / 1024).toFixed(1)} MB`
                    : "--"}
                </span>
              ),
            },
            {
              key: "error",
              header: "Error",
              render: (r) => (
                <span className="text-xs text-error">{r.errorMessage ?? r.importLastError ?? "--"}</span>
              ),
            },
            {
              key: "inserted",
              header: "Created",
              render: (r) => (
                <span className="text-xs">{new Date(r.insertedAt).toLocaleString()}</span>
              ),
            },
            {
              key: "actions",
              header: "Actions",
              render: (r) => (
                <div className="flex gap-1">
                  {!r.completedAt && (
                    <Button
                      size="xs"
                      variant="warning"
                      onClick={() => handleCancel(r.id)}
                    >
                      Cancel
                    </Button>
                  )}
                  <Button
                    size="xs"
                    variant="info"
                    onClick={() => handleMatchOpen(r.id)}
                  >
                    Match
                  </Button>
                </div>
              ),
            },
          ]}
          rows={downloads}
          keyExtractor={(r) => r.id}
          emptyMessage="No downloads found."
        />
      </Card>

      <Modal ref={modalRef} title="Manually Match Download" onClose={() => setMatchError(null)}>
        <div className="flex flex-col gap-3">
          {matchError && <Alert kind="error">{matchError}</Alert>}
          <Input
            label="Media Item ID"
            placeholder="Enter the media item UUID"
            value={mediaIdInput}
            onChange={(e) => setMediaIdInput(e.target.value)}
          />
          <div className="flex justify-end gap-2 mt-2">
            <Button variant="ghost" onClick={() => modalRef.current?.close()}>
              Cancel
            </Button>
            <Button loading={matching} onClick={handleMatch}>
              Match
            </Button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
