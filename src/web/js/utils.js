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
  if (seconds == null || seconds < 0) return "0s";
  const totalSecs = Math.round(seconds);
  const h = Math.floor(totalSecs / 3600);
  const m = Math.floor((totalSecs % 3600) / 60);
  const s = totalSecs % 60;

  const parts = [];
  if (h > 0) parts.push(`${h}h`);
  if (m > 0 || h > 0) parts.push(`${m}m`);
  parts.push(`${s}s`);
  return parts.join(" ");
}

// Helper: Calculate aspect ratio
function calculateAspectRatio(w, h) {
  if (!w || !h || w <= 0 || h <= 0) return "—";
  const intW = Math.round(w);
  const intH = Math.round(h);
  function gcd(a, b) {
    return b === 0 ? a : gcd(b, a % b);
  }
  const r = gcd(intW, intH);
  return `${intW / r}:${intH / r}`;
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

// Copy text to clipboard with optional button checkmark feedback and toast notification
async function copyToClipboard(text, btnElement = null) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
    } else {
      // Fallback for non-secure HTTP contexts (e.g. accessing Synology local IP)
      const textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.style.position = "fixed"; // Keep offscreen/avoid layout shifts
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      const successful = document.execCommand("copy");
      document.body.removeChild(textarea);
      if (!successful) throw new Error("Fallback copy command failed");
    }
    if (btnElement && btnElement.classList) {
      btnElement.classList.add("copied");
      if (btnElement._copyTimeout) {
        clearTimeout(btnElement._copyTimeout);
      }
      btnElement._copyTimeout = setTimeout(() => {
        btnElement.classList.remove("copied");
        btnElement._copyTimeout = null;
      }, 1500);
    }
    showToast("Copied to clipboard", "success");
  } catch (err) {
    console.error("Failed to copy text:", err);
    showToast("Failed to copy to clipboard", "error");
  }
}

// Global toast notification system
function showToast(message, type = "info", durationMs = 2800) {
  const container = document.getElementById("toast-container");
  if (!container) return () => {};

  const toast = document.createElement("div");
  toast.className = `toast toast-${type}`;
  toast.setAttribute("role", "status");

  const icons = {
    info: "info",
    success: "check-circle",
    warning: "alert-triangle",
    error: "alert-circle",
  };
  const iconName = icons[type] || "info";

  toast.innerHTML = `
    <span class="toast-icon" aria-hidden="true"><i data-lucide="${iconName}"></i></span>
    <span class="toast-message">${escapeHtml(message)}</span>
    <button type="button" class="toast-close" aria-label="Dismiss notification">
      <i data-lucide="x" aria-hidden="true"></i>
    </button>
  `;

  container.appendChild(toast);

  if (
    typeof lucide !== "undefined" &&
    typeof lucide.createIcons === "function"
  ) {
    lucide.createIcons({ root: toast });
  }

  // Force reflow for enter transition
  void toast.offsetWidth;
  toast.classList.add("toast-visible");

  let timeoutId = null;
  const dismiss = () => {
    if (timeoutId) {
      clearTimeout(timeoutId);
      timeoutId = null;
    }
    toast.classList.remove("toast-visible");
    toast.classList.add("toast-hiding");
    toast.addEventListener(
      "transitionend",
      () => {
        toast.remove();
      },
      { once: true },
    );
  };

  toast.querySelector(".toast-close")?.addEventListener("click", dismiss);

  if (durationMs > 0) {
    timeoutId = setTimeout(dismiss, durationMs);

    toast.addEventListener("mouseenter", () => {
      if (timeoutId) clearTimeout(timeoutId);
    });
    toast.addEventListener("mouseleave", () => {
      timeoutId = setTimeout(dismiss, Math.max(1200, durationMs / 2));
    });
  }

  return dismiss;
}

// Check if user is currently interacting with an input, textarea, or select
function isInputFocused(el = document.activeElement) {
  if (!el) return false;
  const tag = el.tagName;
  return (
    tag === "INPUT" ||
    tag === "TEXTAREA" ||
    tag === "SELECT" ||
    el.isContentEditable === true
  );
}

// Check if any modal or details drawer is currently open
function isAnyModalOrDrawerOpen() {
  const drawer = document.getElementById("details-drawer");
  if (drawer && drawer.classList.contains("open")) return true;
  const lightbox = document.getElementById("lightbox-modal");
  if (lightbox && lightbox.classList.contains("open")) return true;
  const modals = document.querySelectorAll(".modal.open");
  return modals.length > 0;
}

// Calculate the number of columns in the media grid layout
function getGridColumnCount() {
  const grid = document.getElementById("media-grid");
  if (!grid || !grid.children.length) return 4;
  const cards = grid.querySelectorAll(".grid-card");
  if (cards.length < 2) return 1;
  const firstTop = cards[0].offsetTop;
  let cols = 0;
  for (let i = 0; i < cards.length; i++) {
    if (cards[i].offsetTop === firstTop) {
      cols++;
    } else {
      break;
    }
  }
  return Math.max(1, cols);
}

// Set active catalog selected item index and update DOM highlights
function setSelectedIndex(index, { scrollToView = true, focus = false } = {}) {
  if (index < 0 || index >= mediaData.length) {
    selectedIndex = -1;
  } else {
    selectedIndex = index;
  }

  // Update table row selection
  const tableRows = document.querySelectorAll(
    "#media-tbody tr[data-row-index]",
  );
  tableRows.forEach((tr, i) => {
    const isSel = i === selectedIndex;
    tr.classList.toggle("is-selected", isSel);
    tr.setAttribute("aria-selected", isSel ? "true" : "false");
  });

  // Update grid card selection
  const gridCards = document.querySelectorAll(
    "#media-grid .grid-card[data-row-index]",
  );
  gridCards.forEach((card, i) => {
    const isSel = i === selectedIndex;
    card.classList.toggle("is-selected", isSel);
    card.setAttribute("aria-selected", isSel ? "true" : "false");
  });

  if (selectedIndex !== -1) {
    const activeLayout =
      document
        .getElementById("catalog-table")
        ?.getAttribute("data-view-layout") || "list";
    const activeEl =
      activeLayout === "grid"
        ? document.querySelector(
            `#media-grid .grid-card[data-row-index="${selectedIndex}"]`,
          )
        : document.querySelector(
            `#media-tbody tr[data-row-index="${selectedIndex}"]`,
          );

    if (activeEl) {
      if (scrollToView) {
        activeEl.scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
      if (focus) {
        activeEl.focus();
      }
    }
  }
}

// Resolve the currently active color scheme ("light" or "dark")
function getResolvedTheme() {
  try {
    const stored = localStorage.getItem("color-scheme");
    if (stored === "light" || stored === "dark") return stored;
  } catch (_) {}
  const attr = document.documentElement.dataset.theme;
  if (attr === "light" || attr === "dark") return attr;
  return window.matchMedia &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

// Apply stored theme override (or null for system default) to DOM and active charts
function applyThemeState(storedScheme) {
  const root = document.documentElement;
  root.classList.add("theme-switching");
  const meta = document.querySelector('meta[name="color-scheme"]');
  if (storedScheme === "light" || storedScheme === "dark") {
    if (meta) meta.content = storedScheme;
    root.dataset.theme = storedScheme;
  } else {
    if (meta) meta.content = "light dark";
    delete root.dataset.theme;
  }
  updateThemeToggleButton();
  if (typeof refreshChartsTheme === "function") {
    refreshChartsTheme();
  }
  // Force synchronous style/layout flush before re-enabling CSS transitions
  void root.offsetHeight;
  requestAnimationFrame(() => {
    root.classList.remove("theme-switching");
  });
}

// Update aria-label and title on the header theme toggle button
function updateThemeToggleButton() {
  const btn = document.getElementById("theme-toggle-btn");
  if (!btn) return;
  const current = getResolvedTheme();
  const nextLabel =
    current === "dark"
      ? "Switch to light theme (T)"
      : "Switch to dark theme (T)";
  btn.setAttribute("title", nextLabel);
  btn.setAttribute(
    "aria-label",
    current === "dark" ? "Switch to light theme" : "Switch to dark theme",
  );
}

// Toggle opposite of currently rendered scheme; remove stored value if target matches system
function toggleTheme() {
  const current = getResolvedTheme();
  const target = current === "dark" ? "light" : "dark";
  const systemScheme =
    window.matchMedia &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
      ? "dark"
      : "light";

  let stored = null;
  try {
    if (target !== systemScheme) {
      localStorage.setItem("color-scheme", target);
      stored = target;
    } else {
      localStorage.removeItem("color-scheme");
      stored = null;
    }
  } catch (_) {
    stored = target !== systemScheme ? target : null;
  }

  applyThemeState(stored);
  showToast(
    `Switched to ${target === "dark" ? "Dark" : "Light"} Mode`,
    "info",
    1800,
  );
}
