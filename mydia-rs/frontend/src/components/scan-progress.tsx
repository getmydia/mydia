interface ScanProgressProps {
  stage?: string;
  current?: number;
  total?: number;
  filesFound?: number;
  status: "idle" | "starting" | "scanning" | "complete" | "failed";
  error?: string;
}

export function ScanProgress({
  stage,
  current,
  total,
  filesFound,
  status,
  error,
}: ScanProgressProps) {
  if (status === "idle") return null;

  if (status === "failed") {
    return (
      <div className="flex items-center gap-2 text-sm text-error">
        <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <circle cx="12" cy="12" r="10" />
          <line x1="12" y1="8" x2="12" y2="12" />
          <line x1="12" y1="16" x2="12.01" y2="16" />
        </svg>
        <span>{error ?? "Scan failed"}</span>
      </div>
    );
  }

  if (status === "complete") {
    const summary = buildCompletedSummary(filesFound);
    return (
      <div className="flex items-center gap-2 text-sm text-success">
        <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <circle cx="12" cy="12" r="10" />
          <path d="M9 12l2 2 4-4" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
        <span>{summary}</span>
      </div>
    );
  }

  const label = buildLabel(stage, current, total, filesFound);
  const hasProgress = current != null && total != null && total > 0;

  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-center gap-2 text-sm text-base-content/70">
        <span className="loading loading-spinner loading-xs" />
        <span>{label}</span>
      </div>
      {hasProgress ? (
        <progress
          className="progress progress-primary w-full"
          value={current}
          max={total}
        />
      ) : (
        <progress className="progress progress-primary w-full" />
      )}
    </div>
  );
}

function buildLabel(
  stage?: string,
  current?: number,
  total?: number,
  filesFound?: number,
): string {
  const stageText = stage ? humanizeStage(stage) : "Scanning";
  if (current != null && total != null) {
    return `${stageText}: ${current} of ${total}`;
  }
  if (filesFound != null) {
    return `${stageText}: ${filesFound} files found`;
  }
  return stageText;
}

function humanizeStage(stage: string): string {
  switch (stage) {
    case "creating_files":
      return "Importing new files";
    case "updating_files":
      return "Updating modified files";
    case "deleting_files":
      return "Removing deleted files";
    default:
      return stage.replace(/_/g, " ");
  }
}

function buildCompletedSummary(filesFound?: number): string {
  if (filesFound != null) return `Scan complete: ${filesFound} files`;
  return "Scan complete";
}
