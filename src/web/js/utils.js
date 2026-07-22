// Helper: escape HTML tags
function escapeHtml(str) {
  if (!str) return "";
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

// Convert raw byte count into human-readable string representation
function formatBytes(bytes) {
  if (bytes === 0) return "0 Bytes";
  const k = 1024;
  const sizes = ["Bytes", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  const val = bytes / Math.pow(k, i);
  // Do not show decimal places for bytes or kilobytes
  const decimals = i > 1 ? 2 : 0;
  return `${parseFloat(val.toFixed(decimals))} ${sizes[i]}`;
}

// Format a duration in seconds to a human-readable string (e.g. 1h 30m 15s)
function formatDuration(seconds) {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.round(seconds % 60);

  const parts = [];
  if (h > 0) parts.push(`${h}h`);
  if (m > 0 || h > 0) parts.push(`${m}m`);
  parts.push(`${s}s`);
  return parts.join(" ");
}

// Helper: Calculate aspect ratio
function calculateAspectRatio(w, h) {
  function gcd(a, b) {
    return b == 0 ? a : gcd(b, a % b);
  }
  const r = gcd(w, h);
  return `${w / r}:${h / r}`;
}

// Helper: Format create_time for table display
function formatCaptureDate(createTime) {
  if (!createTime) return "—";
  const normalized = createTime.replace(/^(\d{4}):(\d{2}):(\d{2})/, "$1-$2-$3");
  const datePart = normalized.slice(0, 10);
  const [year, month, day] = datePart.split("-");
  if (!year || !month || !day) return escapeHtml(normalized);
  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  const monthIdx = parseInt(month, 10) - 1;
  if (monthIdx < 0 || monthIdx > 11) return escapeHtml(datePart);
  return `${day} ${months[monthIdx]} ${year}`;
}

// Format a Date object to an ISO date string (YYYY-MM-DD)
function toIsoDate(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

// Format an ISO date string for display in the filter UI
function formatFilterDate(isoDate) {
  if (!isoDate) return "";
  const parts = isoDate.split("-");
  if (parts.length < 3) return isoDate;
  const [year, month, day] = parts;
  const months = [
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
  ];
  const mIdx = parseInt(month, 10) - 1;
  const mLabel = mIdx >= 0 && mIdx < 12 ? months[mIdx] : month;
  return `${parseInt(day, 10)} ${mLabel} ${year}`;
}

// Generate a human-readable size threshold label (e.g. >= 1 GB)
function formatSizeMbLabel(mb) {
  if (mb >= 1024) {
    const gb = mb / 1024;
    return `&ge; ${gb % 1 === 0 ? gb : gb.toFixed(1)} GB`;
  }
  return `&ge; ${mb} MB`;
}

// Format numbers with locale grouping separators
function formatCount(n) {
  return typeof n === "number" ? n.toLocaleString() : "0";
}

// Helper: Highlight query matches with safe HTML escaping
function highlightMatch(text, query) {
  if (!text) return "";
  if (!query) return escapeHtml(text);
  const trimmedQuery = query.trim();
  if (!trimmedQuery) return escapeHtml(text);

  // Escape regex characters in the query
  const escapedQuery = trimmedQuery.replace(/[-\/\\^$*+?.()|[\]{}]/g, "\\$&");
  const regex = new RegExp(`(${escapedQuery})`, "gi");

  // Split the raw unescaped text by the query to prevent matching inside HTML entities like &amp;
  const parts = text.split(regex);
  return parts
    .map((part) => {
      if (part.toLowerCase() === trimmedQuery.toLowerCase()) {
        return `<mark class="search-highlight">${escapeHtml(part)}</mark>`;
      }
      return escapeHtml(part);
    })
    .join("");
}

// Helper: Collect focusable elements inside a dialog container
function getFocusableElements(container) {
  return Array.from(
    container.querySelectorAll(
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    ),
  ).filter((el) => !el.hasAttribute("disabled") && el.offsetParent !== null);
}

// Helper: Keep Tab focus cycling within an open dialog
function trapFocus(e, container) {
  if (e.key !== "Tab") return;
  const focusable = getFocusableElements(container);
  if (focusable.length === 0) return;
  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault();
    last.focus();
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault();
    first.focus();
  }
}

// Determine if a media row represents a video based on format or duration
function isVideo(row) {
  return (
    VIDEO_FORMATS.includes((row.format || "").toLowerCase()) ||
    row.duration_sec !== null
  );
}

// Generate HTML for the media thumbnail or an icon fallback
function renderThumbnailHtml(row, imgClass = "", altText = "") {
  const isVid = isVideo(row);
  if (row.has_thumbnail) {
    const url = `/api/thumbnail?path=${encodeURIComponent(row.path)}`;
    const overlayClass = imgClass
      ? `${imgClass} animated-overlay`
      : "animated-overlay";
    const animatedOverlay = row.has_animated
      ? `<img src="/api/thumbnail?path=${encodeURIComponent(row.path)}&animated=1" class="${overlayClass}" alt="" loading="lazy" decoding="async" fetchpriority="low" aria-hidden="true" />`
      : "";
    const mainImgClass = imgClass ? ` class="${imgClass}"` : "";
    return `${animatedOverlay}<img src="${escapeHtml(url)}"${mainImgClass} alt="${escapeHtml(altText)}" loading="lazy" decoding="async" fetchpriority="low" />`;
  } else if (isVid) {
    return `<i data-lucide="video" class="type-icon video-icon"></i>`;
  } else {
    return `<i data-lucide="image" class="type-icon image-icon"></i>`;
  }
}

// Format duration to digital clock format (e.g. 1:05:30)
function formatDigitalDuration(seconds) {
  if (seconds == null) return "";
  const secs = Math.round(seconds);
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  if (h > 0) {
    return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  }
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}
