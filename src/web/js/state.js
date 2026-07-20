let mediaData = [];
let totalRecords = 0;
let currentPage = 1;
let pageSize = 25;
let sortConfig = { key: "path", direction: "asc" };
let activeModalTab = "images";
let currentFetchController = null;
let statsData = null;
let activeDatePreset = null;
let activeSizePresetMb = null;
let drawerReturnFocus = null;
let modalReturnFocus = null;
let modalSessionId = 0;

const FILTER_DEBOUNCE_MS = 500;

let imgFormatChart = null;
let imgSizeChart = null;
let imgCameraChart = null;

let vidFormatChart = null;
let vidSizeChart = null;
let vidDurationChart = null;

let chartJsLoadPromise = null;

const ORIENTATION_LABELS = {
  1: "Horizontal (normal)",
  2: "Mirror horizontal",
  3: "Rotated 180\u00b0",
  4: "Mirror vertical",
  5: "Mirror horizontal and rotated 270\u00b0 CW",
  6: "Rotated 90\u00b0 CW",
  8: "Rotated 270\u00b0 CW",
};

// VIDEO_FORMATS must mirror media_scan.videoExtensions and db/types.zig video_formats_sql.
const VIDEO_FORMATS = ["mp4", "m4v", "webm", "mkv", "mov", "avi", "wmv", "flv"];

function loadChartJs() {
  if (window.Chart) return Promise.resolve();
  if (!chartJsLoadPromise) {
    chartJsLoadPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "/js/chart.umd.js";
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Failed to load Chart.js"));
      document.head.appendChild(script);
    });
  }
  return chartJsLoadPromise;
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

function handleDrawerKeydown(e) {
  const drawer = document.getElementById("details-drawer");
  if (!drawer.classList.contains("open")) return;
  trapFocus(e, drawer);
}

function handleModalKeydown(e) {
  const modal = document.getElementById("insights-modal");
  if (!modal.classList.contains("open")) return;
  const dialog = modal.querySelector(".modal-content");
  if (dialog) trapFocus(e, dialog);
}

function handleModalBackdropClick(event) {
  const modal = document.getElementById("insights-modal");
  if (event.target === modal) {
    toggleModal(false);
  }
}

function handleModalTablistKeydown(e) {
  if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
  const modal = document.getElementById("insights-modal");
  if (!modal.classList.contains("open")) return;
  const tabs = ["images", "videos"];
  const idx = tabs.indexOf(activeModalTab);
  if (idx === -1) return;
  e.preventDefault();
  const nextIdx =
    e.key === "ArrowRight"
      ? (idx + 1) % tabs.length
      : (idx - 1 + tabs.length) % tabs.length;
  const nextTab = tabs[nextIdx];
  switchModalTab(nextTab);
  document.getElementById(`tab-btn-${nextTab}`)?.focus();
}

function updateSortAriaIndicators() {
  document.querySelectorAll("#media-table th[data-sort]").forEach((th) => {
    const key = th.getAttribute("data-sort");
    if (key === sortConfig.key) {
      th.setAttribute(
        "aria-sort",
        sortConfig.direction === "asc" ? "ascending" : "descending",
      );
    } else {
      th.setAttribute("aria-sort", "none");
    }
  });
}

// Helper: Copy text to clipboard and show visual checkmark feedback
async function copyToClipboard(text, btnElement) {
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
    btnElement.classList.add("copied");
    setTimeout(() => {
      btnElement.classList.remove("copied");
    }, 1500);
  } catch (err) {
    console.error("Failed to copy text:", err);
  }
}

// Helper: Handler for copy buttons in drawer
function copyValue(btnElement) {
  const valSpan = btnElement.previousElementSibling;
  if (valSpan) {
    copyToClipboard(valSpan.textContent.trim(), btnElement);
    // Clear any selection range that might be triggered by browser behavior
    if (window.getSelection) {
      window.getSelection().removeAllRanges();
    }
  }
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

function toIsoDate(date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function getAdvancedFilterParams() {
  const dateFrom = document.getElementById("filter-date-from").value;
  const dateTo = document.getElementById("filter-date-to").value;
  const sizeMin = document.getElementById("filter-size-min").value;
  const sizeMax = document.getElementById("filter-size-max").value;

  return {
    date_from: dateFrom ? dateFrom : null,
    date_to: dateTo ? dateTo : null,
    size_min: sizeMin ? parseFloat(sizeMin) * 1024 * 1024 : null,
    size_max: sizeMax ? parseFloat(sizeMax) * 1024 * 1024 : null,
  };
}

function getDatePresetValues(preset) {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  switch (preset) {
    case "today":
      return { from: toIsoDate(today), to: toIsoDate(today) };
    case "yesterday": {
      const yesterday = new Date(today);
      yesterday.setDate(yesterday.getDate() - 1);
      return { from: toIsoDate(yesterday), to: toIsoDate(yesterday) };
    }
    case "week": {
      const dayOfWeek = today.getDay(); // 0 is Sunday
      const startOfWeek = new Date(today);
      startOfWeek.setDate(today.getDate() - dayOfWeek);
      return { from: toIsoDate(startOfWeek), to: toIsoDate(now) };
    }
    case "month": {
      const startOfMonth = new Date(today.getFullYear(), today.getMonth(), 1);
      return { from: toIsoDate(startOfMonth), to: toIsoDate(now) };
    }
    case "year": {
      const startOfYear = new Date(today.getFullYear(), 0, 1);
      return { from: toIsoDate(startOfYear), to: toIsoDate(now) };
    }
    default:
      return { from: "", to: "" };
  }
}

function updateDatePresetActiveState() {
  document.querySelectorAll("[data-date-preset]").forEach((btn) => {
    const preset = btn.getAttribute("data-date-preset");
    if (preset === activeDatePreset) {
      btn.classList.add("active");
      btn.setAttribute("aria-pressed", "true");
    } else {
      btn.classList.remove("active");
      btn.setAttribute("aria-pressed", "false");
    }
  });
}

function setActiveDatePreset(preset) {
  activeDatePreset = preset;
  updateDatePresetActiveState();
}

function clearDatePresetActive() {
  activeDatePreset = null;
  updateDatePresetActiveState();
}

function applyDatePreset(preset) {
  const { from, to } = getDatePresetValues(preset);
  document.getElementById("filter-date-from").value = from;
  document.getElementById("filter-date-to").value = to;
  setActiveDatePreset(preset);
}

function updateSizePresetActiveState() {
  document.querySelectorAll("[data-size-min-mb]").forEach((btn) => {
    const minMb = parseInt(btn.getAttribute("data-size-min-mb"), 10);
    if (minMb === activeSizePresetMb) {
      btn.classList.add("active");
      btn.setAttribute("aria-pressed", "true");
    } else {
      btn.classList.remove("active");
      btn.setAttribute("aria-pressed", "false");
    }
  });
}

function setActiveSizePreset(minMb) {
  activeSizePresetMb = minMb;
  updateSizePresetActiveState();
}

function clearSizePresetActive() {
  activeSizePresetMb = null;
  updateSizePresetActiveState();
}

function applySizePreset(minMb) {
  document.getElementById("filter-size-min").value = String(minMb);
  document.getElementById("filter-size-max").value = "";
  setActiveSizePreset(minMb);
}

function formatSizeMbLabel(mb) {
  if (mb >= 1024) {
    const gb = mb / 1024;
    return `&ge; ${gb % 1 === 0 ? gb : gb.toFixed(1)} GB`;
  }
  return `&ge; ${mb} MB`;
}

function formatCount(n) {
  return typeof n === "number" ? n.toLocaleString() : "0";
}

function formatFilterDate(isoDate) {
  if (!isoDate) return "";
  const parts = isoDate.split("-");
  if (parts.len < 3) return isoDate;
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

function getActiveFilterKeys() {
  const keys = [];
  if (document.getElementById("search-input").value.trim()) {
    keys.push("search");
  }
  if (document.getElementById("filter-format").value) {
    keys.push("format");
  }
  if (document.getElementById("filter-type").value) {
    keys.push("type");
  }
  const adv = getAdvancedFilterParams();
  if (adv.date_from || adv.date_to) keys.push("date");
  if (adv.size_min !== null || adv.size_max !== null) keys.push("size");
  return keys;
}

function buildSingleFilterEmptyTitle(filterKey) {
  switch (filterKey) {
    case "search": {
      const q = document.getElementById("search-input").value.trim();
      return `No results matching &ldquo;${escapeHtml(q)}&rdquo;`;
    }
    case "format": {
      const f = document.getElementById("filter-format").value;
      return `No files found in the &ldquo;${escapeHtml(f.toUpperCase())}&rdquo; format`;
    }
    case "type": {
      const t = document.getElementById("filter-type").value;
      return `No ${escapeHtml(t)} files found`;
    }
    case "date": {
      const adv = getAdvancedFilterParams();
      if (adv.date_from && adv.date_to) {
        if (adv.date_from === adv.date_to) {
          return `No media files captured on ${escapeHtml(formatFilterDate(adv.date_from))}`;
        }
        return `No files captured between ${escapeHtml(formatFilterDate(adv.date_from))} and ${escapeHtml(formatFilterDate(adv.date_to))}`;
      } else if (adv.date_from) {
        return `No files captured since ${escapeHtml(formatFilterDate(adv.date_from))}`;
      } else {
        return `No files captured before ${escapeHtml(formatFilterDate(adv.date_to))}`;
      }
    }
    case "size": {
      const adv = getAdvancedFilterParams();
      if (adv.size_min !== null && adv.size_max !== null) {
        return `No files between ${escapeHtml(formatBytes(adv.size_min))} and ${escapeHtml(formatBytes(adv.size_max))}`;
      } else if (adv.size_min !== null) {
        return `No files larger than ${escapeHtml(formatBytes(adv.size_min))}`;
      } else {
        return `No files smaller than ${escapeHtml(formatBytes(adv.size_max))}`;
      }
    }
    default:
      return "No matching files found";
  }
}

function describeDateFilter() {
  const adv = getAdvancedFilterParams();
  if (adv.date_from && adv.date_to) {
    if (adv.date_from === adv.date_to) {
      return `on ${formatFilterDate(adv.date_from)}`;
    }
    return `between ${formatFilterDate(adv.date_from)} &ndash; ${formatFilterDate(adv.date_to)}`;
  }
  return adv.date_from
    ? `after ${formatFilterDate(adv.date_from)}`
    : `before ${formatFilterDate(adv.date_to)}`;
}

function describeSizeFilter() {
  const adv = getAdvancedFilterParams();
  if (adv.size_min !== null && adv.size_max !== null) {
    return `${formatBytes(adv.size_min)} to ${formatBytes(adv.size_max)}`;
  }
  return adv.size_min !== null
    ? `&ge; ${formatBytes(adv.size_min)}`
    : `&le; ${formatBytes(adv.size_max)}`;
}

function buildEmptyStateTitle(filterKeys) {
  if (filterKeys.length === 1) {
    return buildSingleFilterEmptyTitle(filterKeys[0]);
  }
  // Compound scenario: summarize active filters
  const parts = [];
  if (filterKeys.includes("type")) {
    const t = document.getElementById("filter-type").value;
    parts.push(t === "image" ? "images" : "videos");
  } else {
    parts.push("files");
  }
  if (filterKeys.includes("format")) {
    const f = document.getElementById("filter-format").value;
    parts[0] = `&ldquo;${escapeHtml(f.toUpperCase())}&rdquo; ${parts[0]}`;
  }
  if (filterKeys.includes("search")) {
    const q = document.getElementById("search-input").value.trim();
    parts.push(`matching &ldquo;${escapeHtml(q)}&rdquo;`);
  }
  if (filterKeys.includes("date")) {
    parts.push(`captured ${describeDateFilter()}`);
  }
  if (filterKeys.includes("size")) {
    parts.push(`sized ${describeSizeFilter()}`);
  }
  const sentence = `No ${parts.join(" ")} found matching your criteria`;
  return sentence.charAt(3).toUpperCase() + sentence.slice(4);
}

function buildSuggestionsForFilter(filterKey) {
  switch (filterKey) {
    case "search": {
      const input = document.getElementById("search-input");
      const currentText = input ? input.value : "";
      return [
        {
          label: "clear search term",
          action: () => {
            if (input) input.value = "";
            triggerFilterRefresh();
          },
        },
      ];
    }
    case "format": {
      const select = document.getElementById("filter-format");
      const fmt = select ? select.value : "";
      return [
        {
          label: `remove &ldquo;${fmt.toUpperCase()}&rdquo; format filter`,
          action: () => {
            if (select) select.value = "";
            triggerFilterRefresh();
          },
        },
      ];
    }
    case "type": {
      const select = document.getElementById("filter-type");
      const type = select ? select.value : "";
      return [
        {
          label: `show all media types (including ${type === "image" ? "videos" : "images"})`,
          action: () => {
            if (select) {
              select.value = "";
              updateFormatFilterOptions();
            }
            triggerFilterRefresh();
          },
        },
      ];
    }
    case "date": {
      const from = document.getElementById("filter-date-from");
      const to = document.getElementById("filter-date-to");
      return [
        {
          label: "clear date range",
          action: () => {
            if (from) from.value = "";
            if (to) to.value = "";
            clearDatePresetActive();
            triggerFilterRefresh();
          },
        },
      ];
    }
    case "size": {
      const min = document.getElementById("filter-size-min");
      const max = document.getElementById("filter-size-max");
      return [
        {
          label: "clear size constraints",
          action: () => {
            if (min) min.value = "";
            if (max) max.value = "";
            clearSizePresetActive();
            triggerFilterRefresh();
          },
        },
      ];
    }
    default:
      return [];
  }
}

function buildEmptyStateSuggestions(filterKeys) {
  const suggestions = [];
  filterKeys.forEach((k) => {
    suggestions.push(...buildSuggestionsForFilter(k));
  });

  if (filterKeys.length > 1) {
    suggestions.push({
      label: "clear all filters",
      action: () => {
        clearAdvancedFilters();
        updateFormatFilterOptions();
        currentPage = 1;
        fetchMedia();
      },
    });
  }
  return suggestions;
}

function formatEmptyStateHint(buttons) {
  if (buttons.length === 0) return "";
  if (buttons.length === 1) {
    return `Try adjusting your query or click to <button class="empty-state-action" data-suggestion-idx="0">${buttons[0].label}</button>.`;
  }
  const listItems = buttons
    .map(
      (btn, idx) =>
        `<li><button class="empty-state-action" data-suggestion-idx="${idx}">${btn.label}</button></li>`,
    )
    .join("");
  return `Try one of the following adjustments: <ul style="list-style: none; padding: 0.5rem 0 0 0; display: flex; flex-direction: column; gap: 0.35rem; align-items: center;">${listItems}</ul>`;
}

let activeEmptyStateActions = [];

function buildEmptyStateHtml() {
  const activeKeys = getActiveFilterKeys();
  if (activeKeys.length === 0) {
    activeEmptyStateActions = [];
    return `
      <div class="empty-state-content">
          <span class="empty-state-title">No media cataloged yet</span>
          <span class="empty-state-hint">Scan a directory using the CLI to populate insights dashboard.</span>
      </div>
    `;
  }
  const title = buildEmptyStateTitle(activeKeys);
  const suggestionData = buildEmptyStateSuggestions(activeKeys);
  activeEmptyStateActions = suggestionData.map((s) => s.action);

  return `
    <div class="empty-state-content">
        <span class="empty-state-title">${title}</span>
        <span class="empty-state-hint">${formatEmptyStateHint(suggestionData)}</span>
    </div>
  `;
}

function handleEmptyStateAction(btn) {
  const idx = parseInt(btn.getAttribute("data-suggestion-idx"), 10);
  if (!Number.isNaN(idx) && activeEmptyStateActions[idx]) {
    activeEmptyStateActions[idx]();
  }
}

function setMoreFiltersExpanded(expanded) {
  const bar = document.querySelector(".filter-bar");
  const toggle = document.querySelector(".more-filters-toggle");
  if (!bar || !toggle) return;

  if (expanded) {
    bar.classList.add("is-expanded");
    toggle.classList.add("active");
    toggle.setAttribute("aria-expanded", "true");
    localStorage.setItem("zprobe_advanced_filters_expanded", "true");
    // Move focus to first advanced input field when opening drawer panel
    document.getElementById("filter-date-from")?.focus();
  } else {
    bar.classList.remove("is-expanded");
    toggle.classList.remove("active");
    toggle.setAttribute("aria-expanded", "false");
    localStorage.setItem("zprobe_advanced_filters_expanded", "false");
  }
}

function initMoreFiltersToggle() {
  const toggle = document.querySelector(".more-filters-toggle");
  if (!toggle) return;

  toggle.addEventListener("click", () => {
    const isExpanded =
      document
        .querySelector(".filter-bar")
        ?.classList.contains("is-expanded") ?? false;
    setMoreFiltersExpanded(!isExpanded);
  });

  const savedState = localStorage.getItem("zprobe_advanced_filters_expanded");
  if (savedState === "true") {
    setMoreFiltersExpanded(true);
  }
}

function hasAdvancedFilters() {
  const adv = getAdvancedFilterParams();
  return (
    adv.date_from !== null ||
    adv.date_to !== null ||
    adv.size_min !== null ||
    adv.size_max !== null
  );
}

function hasActiveFilters() {
  const searchVal = document.getElementById("search-input").value.trim();
  const formatFilter = document.getElementById("filter-format").value;
  const typeFilter = document.getElementById("filter-type").value;
  return (
    searchVal.length > 0 ||
    formatFilter.length > 0 ||
    typeFilter.length > 0 ||
    hasAdvancedFilters()
  );
}

function removeFilterChip(key) {
  switch (key) {
    case "search":
      document.getElementById("search-input").value = "";
      break;
    case "format":
      document.getElementById("filter-format").value = "";
      break;
    case "type":
      document.getElementById("filter-type").value = "";
      updateFormatFilterOptions();
      break;
    case "date":
      document.getElementById("filter-date-from").value = "";
      document.getElementById("filter-date-to").value = "";
      clearDatePresetActive();
      break;
    case "size":
      document.getElementById("filter-size-min").value = "";
      document.getElementById("filter-size-max").value = "";
      clearSizePresetActive();
      break;
  }
  currentPage = 1;
  fetchMedia();
}

function updateActiveFilterChips() {
  const container = document.getElementById("active-filters");
  if (!container) return;

  container.innerHTML = "";

  const filterChips = [];

  const searchVal = document.getElementById("search-input").value.trim();
  if (searchVal) {
    filterChips.push({
      key: "search",
      label: `Search: ${searchVal}`,
    });
  }

  const formatFilter = document.getElementById("filter-format").value;
  if (formatFilter) {
    filterChips.push({
      key: "format",
      label: `Format: ${formatFilter.toUpperCase()}`,
    });
  }

  const typeFilter = document.getElementById("filter-type").value;
  if (typeFilter) {
    filterChips.push({
      key: "type",
      label: `Type: ${typeFilter.charAt(0).toUpperCase() + typeFilter.slice(1)}`,
    });
  }

  const adv = getAdvancedFilterParams();
  if (adv.date_from || adv.date_to) {
    filterChips.push({
      key: "date",
      label: `Date: ${describeDateFilter()}`,
    });
  }

  if (adv.size_min !== null || adv.size_max !== null) {
    filterChips.push({
      key: "size",
      label: `Size: ${describeSizeFilter()}`,
    });
  }

  filterChips.forEach((chip) => {
    const div = document.createElement("div");
    div.className = "filter-chip";
    div.setAttribute("data-filter-key", chip.key);
    div.innerHTML = `
      <span class="filter-chip-label">${chip.label}</span>
      <button class="filter-chip-dismiss" aria-label="Remove filter ${chip.label}">
          <span aria-hidden="true">&times;</span>
      </button>
    `;
    container.appendChild(div);
  });
}

function clearAdvancedFilters() {
  document.getElementById("filter-date-from").value = "";
  document.getElementById("filter-date-to").value = "";
  document.getElementById("filter-size-min").value = "";
  document.getElementById("filter-size-max").value = "";
  document.getElementById("filter-type").value = "";
  document.getElementById("filter-format").value = "";
  document.getElementById("search-input").value = "";
  clearDatePresetActive();
  clearSizePresetActive();
}

function triggerFilterRefresh() {
  currentPage = 1;
  fetchMedia();
}

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

function destroyAllCharts() {
  if (imgFormatChart) {
    imgFormatChart.destroy();
    imgFormatChart = null;
  }
  if (imgSizeChart) {
    imgSizeChart.destroy();
    imgSizeChart = null;
  }
  if (imgCameraChart) {
    imgCameraChart.destroy();
    imgCameraChart = null;
  }
  if (vidFormatChart) {
    vidFormatChart.destroy();
    vidFormatChart = null;
  }
  if (vidSizeChart) {
    vidSizeChart.destroy();
    vidSizeChart = null;
  }
  if (vidDurationChart) {
    vidDurationChart.destroy();
    vidDurationChart = null;
  }
}

function resizeActiveCharts() {
  if (activeModalTab === "images") {
    imgFormatChart?.resize();
    imgSizeChart?.resize();
    imgCameraChart?.resize();
  } else {
    vidFormatChart?.resize();
    vidSizeChart?.resize();
    vidDurationChart?.resize();
  }
}

// Helper to toggle visual placeholders when data is absent
function toggleChartPlaceholder(wrapperId, hasData, message) {
  const wrapper = document.getElementById(wrapperId);
  if (!wrapper) return;

  const canvas = wrapper.querySelector("canvas");
  let placeholder = wrapper.querySelector(".chart-placeholder");

  if (!hasData) {
    if (canvas) canvas.style.display = "none";
    if (!placeholder) {
      placeholder = document.createElement("div");
      placeholder.className = "chart-placeholder";
      wrapper.appendChild(placeholder);
    }
    placeholder.textContent = message;
    placeholder.style.display = "flex";
  } else {
    if (canvas) canvas.style.display = "block";
    if (placeholder) placeholder.style.display = "none";
  }
}
