interface StatusPillProps {
  status: string;
  label?: string;
  className?: string;
}

const statusBadgeClass = (status: string): string => {
  switch (status) {
    case "completed":
    case "approved":
    case "ready":
    case "active":
    case "succeeded":
      return "badge-success";
    case "failed":
    case "rejected":
    case "discarded":
    case "exception":
    case "error":
    case "revoked":
      return "badge-error";
    case "cancelled":
    case "retryable":
    case "inactive":
      return "badge-warning";
    case "pending":
    case "scheduled":
    case "waiting":
      return "badge-info";
    case "executing":
    case "running":
    case "transcoding":
    case "in_progress":
    case "engage":
      return "badge-primary";
    default:
      return "badge-ghost";
  }
};

const humanizeStatus = (status: string): string => {
  const chars = status.replace(/_/g, " ");
  return chars.charAt(0).toUpperCase() + chars.slice(1);
};

export function StatusPill({
  status,
  label,
  className = "",
}: StatusPillProps) {
  const badgeClass = statusBadgeClass(status);
  const displayLabel = label ?? humanizeStatus(status);

  return (
    <span className={["badge", badgeClass, className].filter(Boolean).join(" ")}>
      {displayLabel}
    </span>
  );
}
