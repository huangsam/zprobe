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
  return `${months[monthIdx]} ${parseInt(day, 10)}, ${year}`;
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
  const sizeMinMb = document.getElementById("filter-size-min").value;
  const sizeMaxMb = document.getElementById("filter-size-max").value;

  const params = {};
  if (dateFrom) params.date_from = dateFrom;
  if (dateTo) params.date_to = dateTo;
  if (sizeMinMb) {
    const parsed = parseInt(sizeMinMb, 10);
    if (!Number.isNaN(parsed) && parsed >= 0) {
      params.size_min = parsed * 1024 * 1024;
    }
  }
  if (sizeMaxMb) {
    const parsed = parseInt(sizeMaxMb, 10);
    if (!Number.isNaN(parsed) && parsed >= 0) {
      params.size_max = parsed * 1024 * 1024;
    }
  }
  return params;
}

function getDatePresetValues(preset) {
  const today = new Date();
  if (preset === "last7") {
    const from = new Date(today);
    from.setDate(from.getDate() - 7);
    return { from: toIsoDate(from), to: toIsoDate(today) };
  }
  if (preset === "this-month") {
    const from = new Date(today.getFullYear(), today.getMonth(), 1);
    return { from: toIsoDate(from), to: toIsoDate(today) };
  }
  if (preset === "this-year") {
    return {
      from: `${today.getFullYear()}-01-01`,
      to: toIsoDate(today),
    };
  }
  return null;
}

function updateDatePresetActiveState() {
  document.querySelectorAll("[data-date-preset]").forEach((btn) => {
    const preset = btn.getAttribute("data-date-preset");
    const isActive = preset === activeDatePreset;
    btn.classList.toggle("active", isActive);
    btn.setAttribute("aria-pressed", isActive ? "true" : "false");
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
  const values = getDatePresetValues(preset);
  if (!values) return;
  document.getElementById("filter-date-from").value = values.from;
  document.getElementById("filter-date-to").value = values.to;
  setActiveDatePreset(preset);
}

function updateSizePresetActiveState() {
  document.querySelectorAll("[data-size-min-mb]").forEach((btn) => {
    const minMb = parseInt(btn.getAttribute("data-size-min-mb"), 10);
    const isActive = activeSizePresetMb === minMb;
    btn.classList.toggle("active", isActive);
    btn.setAttribute("aria-pressed", isActive ? "true" : "false");
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
  const parsed = parseInt(mb, 10);
  if (Number.isNaN(parsed)) return `${mb} MB`;
  if (parsed >= 1024 && parsed % 1024 === 0) {
    return `${parsed / 1024} GB`;
  }
  return `${parsed} MB`;
}

function formatCount(n) {
  return Number(n).toLocaleString();
}

function formatFilterDate(isoDate) {
  if (!isoDate) return "…";
  const [year, month, day] = isoDate.split("-");
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
  if (monthIdx < 0 || monthIdx > 11) return isoDate;
  return `${months[monthIdx]} ${parseInt(day, 10)}, ${year}`;
}

function getActiveFilterKeys() {
  const keys = [];
  const dateFrom = document.getElementById("filter-date-from").value;
  const dateTo = document.getElementById("filter-date-to").value;
  const sizeMinMb = document.getElementById("filter-size-min").value;
  const sizeMaxMb = document.getElementById("filter-size-max").value;
  const formatFilter = document.getElementById("filter-format").value;
  const typeFilter = document.getElementById("filter-type").value;
  const searchVal = document.getElementById("search-input").value.trim();

  if (dateFrom || dateTo) keys.push("date");
  if (sizeMinMb || sizeMaxMb) keys.push("size");
  if (searchVal) keys.push("search");
  if (formatFilter) keys.push("format");
  if (typeFilter) keys.push("type");
  return keys;
}

function buildSingleFilterEmptyTitle(filterKey) {
  const dateFrom = document.getElementById("filter-date-from").value;
  const dateTo = document.getElementById("filter-date-to").value;
  const sizeMinMb = document.getElementById("filter-size-min").value;
  const sizeMaxMb = document.getElementById("filter-size-max").value;
  const formatFilter = document.getElementById("filter-format").value;
  const typeFilter = document.getElementById("filter-type").value;
  const searchVal = document.getElementById("search-input").value.trim();

  switch (filterKey) {
    case "date":
      if (dateFrom && dateTo) {
        return `No files between ${formatFilterDate(dateFrom)} and ${formatFilterDate(dateTo)}.`;
      }
      if (dateFrom) {
        return `No files from ${formatFilterDate(dateFrom)} onward.`;
      }
      return `No files through ${formatFilterDate(dateTo)}.`;
    case "size":
      if (sizeMinMb && sizeMaxMb) {
        return `No files between ${formatSizeMbLabel(sizeMinMb)} and ${formatSizeMbLabel(sizeMaxMb)}.`;
      }
      if (sizeMinMb) {
        return `No files ≥ ${formatSizeMbLabel(sizeMinMb)}.`;
      }
      return `No files ≤ ${formatSizeMbLabel(sizeMaxMb)}.`;
    case "search":
      return `No files matching "${searchVal}".`;
    case "format":
      return `No ${formatFilter.toUpperCase()} files in catalog.`;
    case "type":
      return typeFilter === "image"
        ? "No images match your filters."
        : "No videos match your filters.";
    default:
      return "No matching media files found.";
  }
}

function describeDateFilter() {
  const dateFrom = document.getElementById("filter-date-from").value;
  const dateTo = document.getElementById("filter-date-to").value;
  if (dateFrom && dateTo) {
    return `between ${formatFilterDate(dateFrom)} and ${formatFilterDate(dateTo)}`;
  }
  if (dateFrom) {
    return `from ${formatFilterDate(dateFrom)} onward`;
  }
  return `through ${formatFilterDate(dateTo)}`;
}

function describeSizeFilter() {
  const sizeMinMb = document.getElementById("filter-size-min").value;
  const sizeMaxMb = document.getElementById("filter-size-max").value;
  if (sizeMinMb && sizeMaxMb) {
    return `between ${formatSizeMbLabel(sizeMinMb)} and ${formatSizeMbLabel(sizeMaxMb)}`;
  }
  if (sizeMinMb) {
    return `≥ ${formatSizeMbLabel(sizeMinMb)}`;
  }
  return `≤ ${formatSizeMbLabel(sizeMaxMb)}`;
}

function buildEmptyStateTitle(filterKeys) {
  if (filterKeys.length === 1) {
    return buildSingleFilterEmptyTitle(filterKeys[0]);
  }

  const hasDate = filterKeys.includes("date");
  const hasSize = filterKeys.includes("size");

  if (hasDate && hasSize && filterKeys.length === 2) {
    return `No files ${describeDateFilter()} that are ${describeSizeFilter()}.`;
  }

  if (hasDate && hasSize) {
    return `No files ${describeDateFilter()} that are ${describeSizeFilter()}, with your other filters applied.`;
  }

  return "No files match your current filters.";
}

function buildSuggestionsForFilter(filterKey) {
  const actions = [];

  if (filterKey === "date") {
    if (activeDatePreset !== "this-month") {
      actions.push({
        type: "date-preset",
        preset: "this-month",
        label: "This month",
      });
    } else if (activeDatePreset !== "last7") {
      actions.push({
        type: "date-preset",
        preset: "last7",
        label: "Last 7 days",
      });
    }
    actions.push({
      type: "clear-filter",
      key: "date",
      label: "clear the date filter",
    });
  } else if (filterKey === "size") {
    const sizeMinMb = parseInt(
      document.getElementById("filter-size-min").value,
      10,
    );
    if (!Number.isNaN(sizeMinMb) && sizeMinMb > 10) {
      actions.push({
        type: "size-preset",
        minMb: 10,
        label: "≥ 10 MB",
      });
    }
    if (!Number.isNaN(sizeMinMb) && sizeMinMb > 1) {
      actions.push({
        type: "size-preset",
        minMb: 1,
        label: "≥ 1 MB",
      });
    }
    actions.push({
      type: "clear-filter",
      key: "size",
      label: "clear the size filter",
    });
  } else if (filterKey === "search") {
    actions.push({
      type: "clear-filter",
      key: "search",
      label: "clear search",
    });
  } else if (filterKey === "format") {
    actions.push({
      type: "clear-filter",
      key: "format",
      label: "clear the format filter",
    });
  } else if (filterKey === "type") {
    actions.push({
      type: "clear-filter",
      key: "type",
      label: "clear the type filter",
    });
  }

  return actions;
}

function buildEmptyStateSuggestions(filterKeys) {
  const actions = [];

  for (const key of filterKeys) {
    const keyActions = buildSuggestionsForFilter(key);
    const widen = keyActions.find(
      (action) =>
        action.type === "date-preset" || action.type === "size-preset",
    );
    const clear = keyActions.find((action) => action.type === "clear-filter");
    if (widen) actions.push(widen);
    else if (clear) actions.push(clear);
  }

  if (filterKeys.length > 1) {
    actions.push({ type: "clear-all", label: "clear all filters" });
  }

  return actions.slice(0, 3);
}

function formatEmptyStateHint(buttons) {
  if (buttons.length === 0) return "";
  if (buttons.length === 1) return `Try ${buttons[0]}.`;
  if (buttons.length === 2) return `Try ${buttons[0]} or ${buttons[1]}.`;
  return `Try ${buttons.slice(0, -1).join(", ")}, or ${buttons[buttons.length - 1]}.`;
}

function buildEmptyStateHtml() {
  const filterKeys = getActiveFilterKeys();
  if (filterKeys.length === 0) {
    return `<div class="empty-state-content"><p class="empty-state-title">No matching media files found.</p></div>`;
  }

  const title = buildEmptyStateTitle(filterKeys);
  const actions = buildEmptyStateSuggestions(filterKeys);
  let html = `<div class="empty-state-content"><p class="empty-state-title">${escapeHtml(title)}</p>`;

  if (actions.length > 0) {
    const buttons = actions.map((action) => {
      let attrs = `data-empty-action="${action.type}"`;
      if (action.key) attrs += ` data-filter-key="${action.key}"`;
      if (action.preset) attrs += ` data-preset="${action.preset}"`;
      if (action.minMb != null) attrs += ` data-min-mb="${action.minMb}"`;
      return `<button type="button" class="empty-state-action" ${attrs}>${escapeHtml(action.label)}</button>`;
    });
    html += `<p class="empty-state-hint">${formatEmptyStateHint(buttons)}</p>`;
  }

  html += `</div>`;
  return html;
}

function handleEmptyStateAction(btn) {
  const action = btn.getAttribute("data-empty-action");
  if (action === "clear-filter") {
    removeFilterChip(btn.getAttribute("data-filter-key"));
    return;
  }
  if (action === "clear-all") {
    clearAdvancedFilters();
    updateFormatFilterOptions();
    currentPage = 1;
    fetchMedia();
    return;
  }
  if (action === "date-preset") {
    applyDatePreset(btn.getAttribute("data-preset"));
    setMoreFiltersExpanded(true);
    triggerFilterRefresh();
    return;
  }
  if (action === "size-preset") {
    applySizePreset(parseInt(btn.getAttribute("data-min-mb"), 10));
    setMoreFiltersExpanded(true);
    triggerFilterRefresh();
  }
}

const MORE_FILTERS_STORAGE_KEY = "zprobe-more-filters-expanded";

function setMoreFiltersExpanded(expanded) {
  const advanced = document.getElementById("filter-bar-advanced");
  const toggle = document.getElementById("more-filters-toggle");
  const filterBar = document.getElementById("filter-bar");
  if (!advanced || !toggle || !filterBar) return;

  filterBar.classList.toggle("is-expanded", expanded);
  advanced.classList.toggle("expanded", expanded);
  advanced.setAttribute("aria-hidden", expanded ? "false" : "true");
  toggle.setAttribute("aria-expanded", expanded ? "true" : "false");
  toggle.classList.toggle("active", expanded);

  try {
    localStorage.setItem(MORE_FILTERS_STORAGE_KEY, expanded ? "1" : "0");
  } catch (_) {
    /* ignore storage errors */
  }
}

function initMoreFiltersToggle() {
  const toggle = document.getElementById("more-filters-toggle");
  if (!toggle) return;

  let expanded = false;
  try {
    expanded = localStorage.getItem(MORE_FILTERS_STORAGE_KEY) === "1";
  } catch (_) {
    /* default collapsed */
  }

  setMoreFiltersExpanded(expanded);

  toggle.addEventListener("click", () => {
    const isExpanded = document
      .getElementById("filter-bar")
      ?.classList.contains("is-expanded");
    setMoreFiltersExpanded(!isExpanded);
  });
}

function hasAdvancedFilters() {
  const dateFrom = document.getElementById("filter-date-from").value;
  const dateTo = document.getElementById("filter-date-to").value;
  const sizeMinMb = document.getElementById("filter-size-min").value;
  const sizeMaxMb = document.getElementById("filter-size-max").value;
  return !!(dateFrom || dateTo || sizeMinMb || sizeMaxMb);
}

function hasActiveFilters() {
  return (
    hasAdvancedFilters() ||
    !!document.getElementById("search-input").value.trim() ||
    !!document.getElementById("filter-format").value ||
    !!document.getElementById("filter-type").value
  );
}

const FILTER_CHIP_ARIA = {
  search: "search",
  format: "format",
  type: "type",
  date: "date",
  size: "size",
};

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
    default:
      return;
  }
  triggerFilterRefresh();
}

function updateActiveFilterChips() {
  const container = document.getElementById("active-filters");
  if (!container) return;

  const chips = [];
  const dateFrom = document.getElementById("filter-date-from").value;
  const dateTo = document.getElementById("filter-date-to").value;
  const sizeMinMb = document.getElementById("filter-size-min").value;
  const sizeMaxMb = document.getElementById("filter-size-max").value;
  const formatFilter = document.getElementById("filter-format").value;
  const typeFilter = document.getElementById("filter-type").value;
  const searchVal = document.getElementById("search-input").value.trim();

  if (searchVal) chips.push({ key: "search", label: `Search: ${searchVal}` });
  if (formatFilter) {
    chips.push({
      key: "format",
      label: `Format: ${formatFilter.toUpperCase()}`,
    });
  }
  if (typeFilter) {
    chips.push({
      key: "type",
      label: typeFilter === "image" ? "Images only" : "Videos only",
    });
  }
  if (dateFrom || dateTo) {
    chips.push({
      key: "date",
      label: `Date: ${dateFrom || "…"} → ${dateTo || "…"}`,
    });
  }
  if (sizeMinMb || sizeMaxMb) {
    if (sizeMinMb && sizeMaxMb) {
      chips.push({
        key: "size",
        label: `Size: ${formatSizeMbLabel(sizeMinMb)} – ${formatSizeMbLabel(sizeMaxMb)}`,
      });
    } else if (sizeMinMb) {
      chips.push({
        key: "size",
        label: `Size: ≥ ${formatSizeMbLabel(sizeMinMb)}`,
      });
    } else {
      chips.push({
        key: "size",
        label: `Size: ≤ ${formatSizeMbLabel(sizeMaxMb)}`,
      });
    }
  }

  container.innerHTML = chips
    .map(({ key, label }) => {
      const ariaTarget = FILTER_CHIP_ARIA[key] || key;
      return `<span class="filter-chip" data-filter-key="${key}">
        <span class="filter-chip-label">${escapeHtml(label)}</span>
        <button type="button" class="filter-chip-dismiss" aria-label="Remove ${ariaTarget} filter">&times;</button>
      </span>`;
    })
    .join("");

  const countEl = document.getElementById("filter-result-count");
  if (!countEl) return;

  if (hasActiveFilters() && statsData) {
    const catalogTotal = statsData.total_files;
    countEl.textContent = `Showing ${formatCount(totalRecords)} of ${formatCount(catalogTotal)}`;
    countEl.hidden = false;
  } else {
    countEl.textContent = "";
    countEl.hidden = true;
  }
}

function clearAdvancedFilters() {
  document.getElementById("filter-date-from").value = "";
  document.getElementById("filter-date-to").value = "";
  document.getElementById("filter-size-min").value = "";
  document.getElementById("filter-size-max").value = "";
  document.getElementById("filter-format").value = "";
  document.getElementById("filter-type").value = "";
  document.getElementById("search-input").value = "";
  clearDatePresetActive();
  clearSizePresetActive();
  updateActiveFilterChips();
}

function triggerFilterRefresh() {
  currentPage = 1;
  updateActiveFilterChips();
  fetchMedia();
}

// Helper: Render pulsing skeleton loading rows
function renderSkeletons() {
  const tbody = document.getElementById("media-tbody");
  if (!tbody) return;
  let html = "";
  for (let i = 0; i < 5; i++) {
    html += `
      <tr class="skeleton-row">
        <td class="file-path-cell">
          <div class="file-path-content">
            <div class="thumbnail-wrapper">
              <span class="skeleton-bar thumbnail-bar"></span>
            </div>
            <div class="file-name-container">
              <span class="skeleton-bar name"></span>
              <span class="skeleton-bar dir"></span>
            </div>
          </div>
        </td>
        <td><span class="skeleton-bar date"></span></td>
        <td><span class="skeleton-bar size"></span></td>
        <td><span class="skeleton-bar format"></span></td>
        <td><span class="skeleton-bar dimensions"></span></td>
      </tr>
    `;
  }
  tbody.innerHTML = html;
}

// Helper: Format bytes to human readable format
function formatBytes(bytes) {
  if (bytes === 0) return "0 Bytes";
  const k = 1024;
  const sizes = ["Bytes", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
}

// Helper: Format seconds to human-readable duration (e.g. 2h 3m 7s)
function formatDuration(seconds) {
  if (seconds == null) return "—";
  const total = Math.round(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

// Human-readable labels for EXIF/tkhd orientation values
const ORIENTATION_LABELS = {
  1: "Normal",
  3: "Rotated 180\u00b0",
  6: "Rotated 90\u00b0 CW",
  8: "Rotated 270\u00b0 CW",
};

// Fetch overall stats
async function fetchStats() {
  try {
    const res = await fetch("/api/stats");
    if (!res.ok) throw new Error("Stats request failed");
    statsData = await res.json();
    populateStats();
    updateFormatFilterOptions();
  } catch (err) {
    console.error("Failed to load catalog stats:", err);
  }
}

// Fetch database paged records
async function fetchMedia({
  refetchStats = false,
  showSkeleton = true,
  showRefreshSpinner = false,
} = {}) {
  // Cancel any previous in-flight request so rapid navigation always
  // reflects the latest currentPage without waiting for stale fetches.
  if (currentFetchController) currentFetchController.abort();
  const controller = new AbortController();
  currentFetchController = controller;

  const tbody = document.getElementById("media-tbody");
  const tableContainer = document.querySelector(".table-container");
  if (tableContainer) tableContainer.setAttribute("aria-busy", "true");
  if (showSkeleton) renderSkeletons();

  const refreshBtn = document.getElementById("refresh-btn");
  const refreshIcon = document.querySelector("#refresh-btn .lucide");

  if (showRefreshSpinner) {
    if (refreshBtn) refreshBtn.disabled = true;
    if (refreshIcon) refreshIcon.classList.add("spin");
  }

  const startTime = Date.now();

  try {
    if (refetchStats) {
      await fetchStats();
    }

    // If this request was superseded during the stats fetch, bail out.
    if (controller.signal.aborted) return;

    const searchVal = encodeURIComponent(
      document.getElementById("search-input").value,
    );
    const formatFilter = document.getElementById("filter-format").value;
    const typeFilter = document.getElementById("filter-type").value;
    const sortKey = sortConfig.key === "dimensions" ? "width" : sortConfig.key;
    const sortDir = sortConfig.direction;
    const offset = (currentPage - 1) * pageSize;
    const advancedFilters = getAdvancedFilterParams();

    // Build query URL
    let url = `/api/media?limit=${pageSize}&offset=${offset}&sort=${encodeURIComponent(sortKey)}&order=${sortDir}`;
    if (searchVal) url += `&search=${searchVal}`;
    if (formatFilter) url += `&format=${encodeURIComponent(formatFilter)}`;
    if (typeFilter) url += `&type=${encodeURIComponent(typeFilter)}`;
    if (advancedFilters.date_from) {
      url += `&date_from=${encodeURIComponent(advancedFilters.date_from)}`;
    }
    if (advancedFilters.date_to) {
      url += `&date_to=${encodeURIComponent(advancedFilters.date_to)}`;
    }
    if (advancedFilters.size_min != null) {
      url += `&size_min=${advancedFilters.size_min}`;
    }
    if (advancedFilters.size_max != null) {
      url += `&size_max=${advancedFilters.size_max}`;
    }

    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) throw new Error("API request failed");
    const payload = await res.json();

    mediaData = payload.records;
    totalRecords = payload.total;

    renderTable();
    updatePaginationControls();
    updateActiveFilterChips();
  } catch (err) {
    if (err.name === "AbortError") return;
    console.error(err);
    tbody.innerHTML = `<tr><td colspan="5" class="error-state">Failed to load media catalog: ${err.message}</td></tr>`;
  } finally {
    if (controller === currentFetchController) {
      const elapsedTime = Date.now() - startTime;
      const minDuration = showRefreshSpinner ? 500 : 0;
      const remainingTime = Math.max(0, minDuration - elapsedTime);

      setTimeout(() => {
        if (controller !== currentFetchController) return;
        if (showRefreshSpinner && refreshIcon)
          refreshIcon.classList.remove("spin");
        if (refreshBtn) refreshBtn.disabled = false;
        const tableContainer = document.querySelector(".table-container");
        if (tableContainer) tableContainer.setAttribute("aria-busy", "false");
        currentFetchController = null;
      }, remainingTime);
    }
  }
}

// Calculate and display metrics
function populateStats() {
  if (!statsData) return;
  document.getElementById("stat-total-files").textContent =
    statsData.total_files;
  document.getElementById("stat-total-size").textContent = formatBytes(
    statsData.total_size,
  );
  document.getElementById("stat-images").textContent = statsData.num_images;
  document.getElementById("stat-videos").textContent = statsData.num_videos;

  const summary = document.getElementById("stats-live-summary");
  if (summary) {
    summary.textContent = `Catalog: ${formatCount(statsData.total_files)} files, ${formatBytes(statsData.total_size)} total, ${formatCount(statsData.num_images)} images, ${formatCount(statsData.num_videos)} videos`;
  }
}

// Populate format filter options dynamically based on selected type
function updateFormatFilterOptions() {
  if (!statsData) return;
  const formats = new Set();
  const typeFilter = document.getElementById("filter-type").value;
  const includeImages = typeFilter === "" || typeFilter === "image";
  const includeVideos = typeFilter === "" || typeFilter === "video";
  const allLabel =
    typeFilter === "image"
      ? "All Image Formats"
      : typeFilter === "video"
        ? "All Video Formats"
        : "All Formats";

  if (includeImages && statsData.image_formats) {
    statsData.image_formats.forEach((f) => {
      if (f.format) formats.add(f.format.toUpperCase());
    });
  }
  if (includeVideos && statsData.video_formats) {
    statsData.video_formats.forEach((f) => {
      if (f.format) formats.add(f.format.toUpperCase());
    });
  }

  const sortedFormats = Array.from(formats).sort();
  const select = document.getElementById("filter-format");
  const currentVal = select.value;

  select.innerHTML = `<option value="">${allLabel}</option>`;
  sortedFormats.forEach((fmt) => {
    const opt = document.createElement("option");
    opt.value = fmt.toLowerCase();
    opt.textContent = fmt;
    select.appendChild(opt);
  });
  // Keep selection only when still valid for the chosen media type.
  select.value = sortedFormats.includes(currentVal.toUpperCase())
    ? currentVal
    : "";
}

// Render the table rows
function renderTable() {
  const tbody = document.getElementById("media-tbody");

  if (mediaData.length === 0) {
    tbody.innerHTML = `<tr class="empty-state-row"><td colspan="5" class="empty-state">${buildEmptyStateHtml()}</td></tr>`;
    return;
  }

  const searchInput = document.getElementById("search-input");
  const query = searchInput ? searchInput.value : "";

  tbody.innerHTML = "";
  mediaData.forEach((row, index) => {
    const tr = document.createElement("tr");
    tr.tabIndex = 0;
    tr.setAttribute("role", "button");
    tr.dataset.rowIndex = String(index);

    const dims =
      row.width && row.height ? `${row.width} &times; ${row.height}` : "—";
    const fileBase = row.path.split("/").pop();
    const dirPath = row.path.substring(0, row.path.lastIndexOf("/"));

    tr.setAttribute("aria-label", `View details for ${fileBase}`);

    const isVideo =
      ["mp4", "webm", "mkv", "mov", "avi"].includes(
        (row.format || "").toLowerCase(),
      ) || row.duration_sec !== null;
    let thumbHtml = "";
    if (row.has_thumbnail) {
      const url = `/api/thumbnail?path=${encodeURIComponent(row.path)}`;
      thumbHtml = `<img src="${url}" class="row-thumbnail" alt="Thumbnail" loading="lazy" />`;
    } else if (isVideo) {
      thumbHtml = `<i data-lucide="video" class="type-icon video-icon"></i>`;
    } else {
      thumbHtml = `<i data-lucide="image" class="type-icon image-icon"></i>`;
    }

    tr.innerHTML = `
              <td class="file-path-cell">
                  <div class="file-path-content">
                      <div class="thumbnail-wrapper">
                          ${thumbHtml}
                      </div>
                      <div class="file-name-container">
                          <span class="file-name">${highlightMatch(fileBase, query)}</span>
                          <span class="file-dir" title="${escapeHtml(dirPath)}">${highlightMatch(dirPath, query)}</span>
                      </div>
                  </div>
              </td>
              <td class="date-cell">${formatCaptureDate(row.create_time)}</td>
              <td>${formatBytes(row.size)}</td>
              <td><span class="badge badge-format">${highlightMatch((row.format || "").toUpperCase(), query)}</span></td>
              <td>${dims}</td>
          `;
    tbody.appendChild(tr);
  });
  lucide.createIcons({ root: tbody });
}

// Update UI pagination buttons and info labels
function updatePaginationControls() {
  const totalPages = Math.ceil(totalRecords / pageSize) || 1;
  if (currentPage > totalPages) currentPage = totalPages;

  document.getElementById("page-current").textContent =
    `Page ${currentPage} of ${totalPages}`;

  const pageStart = totalRecords === 0 ? 0 : (currentPage - 1) * pageSize + 1;
  const pageEnd = Math.min(currentPage * pageSize, totalRecords);
  document.getElementById("page-start").textContent = pageStart;
  document.getElementById("page-end").textContent = pageEnd;
  document.getElementById("page-total").textContent = totalRecords;

  document.getElementById("prev-page-btn").disabled = currentPage <= 1;
  document.getElementById("next-page-btn").disabled = currentPage >= totalPages;
}

// Close the details drawer and its backdrop
function closeDrawer() {
  const drawer = document.getElementById("details-drawer");
  drawer.classList.remove("open");
  drawer.setAttribute("aria-hidden", "true");
  document.getElementById("drawer-backdrop").classList.remove("visible");
  document.removeEventListener("keydown", handleDrawerKeydown);
  const returnFocus = drawerReturnFocus;
  drawerReturnFocus = null;
  if (returnFocus && typeof returnFocus.focus === "function") {
    returnFocus.focus();
  }
}

// Show metadata details side drawer
function showDetails(row, triggerEl) {
  const drawer = document.getElementById("details-drawer");
  const content = document.getElementById("drawer-content");
  drawerReturnFocus = triggerEl || document.activeElement;

  const fileBase = row.path.split("/").pop();
  const videoFormats = ["mp4", "webm", "mkv", "mov", "avi"];
  const isVideo =
    videoFormats.includes((row.format || "").toLowerCase()) ||
    row.duration_sec !== null;

  let html = "";
  if (row.has_thumbnail) {
    const url = `/api/thumbnail?path=${encodeURIComponent(row.path)}`;
    html += `
          <div class="drawer-preview-container">
              <img src="${url}" class="drawer-preview-image" alt="Thumbnail Preview" />
          </div>
    `;
  }

  html += `
          <div class="detail-section">
              <h4>File Info</h4>
              <div class="detail-row">
                  <span class="label">Filename:</span>
                  <span class="value-with-action">
                      <span class="value">${escapeHtml(fileBase)}</span>
                      <button class="copy-btn" onclick="copyValue(this)" aria-label="Copy filename">
                          <i data-lucide="copy" aria-hidden="true"></i>
                      </button>
                  </span>
              </div>
              <div class="detail-row">
                  <span class="label">Full Path:</span>
                  <span class="value-with-action">
                      <span class="value">${escapeHtml(row.path)}</span>
                      <button class="copy-btn" onclick="copyValue(this)" aria-label="Copy full path">
                          <i data-lucide="copy" aria-hidden="true"></i>
                      </button>
                  </span>
              </div>
              <div class="detail-row"><span class="label">Size:</span><span class="value">${formatBytes(row.size)} (${row.size} bytes)</span></div>
              <div class="detail-row"><span class="label">Format:</span><span class="value">${escapeHtml((row.format || "").toUpperCase())}</span></div>
          </div>
      `;

  if (row.width && row.height) {
    html += `
              <div class="detail-section">
                  <h4>Dimensions</h4>
                  <div class="detail-row"><span class="label">Width:</span><span class="value">${row.width} px</span></div>
                  <div class="detail-row"><span class="label">Height:</span><span class="value">${row.height} px</span></div>
                  <div class="detail-row"><span class="label">Aspect Ratio:</span><span class="value">${calculateAspectRatio(row.width, row.height)}</span></div>
                  ${row.orientation ? `<div class="detail-row"><span class="label">Orientation:</span><span class="value">${ORIENTATION_LABELS[row.orientation] ?? `EXIF ${row.orientation}`}</span></div>` : ""}
              </div>
          `;
  }

  if (isVideo && row.duration_sec) {
    html += `
              <div class="detail-section">
                  <h4>Video Properties</h4>
                  <div class="detail-row"><span class="label">Duration:</span><span class="value">${formatDuration(row.duration_sec)}</span></div>
              </div>
          `;
  }

  if (row.create_time || row.camera_make || row.camera_model) {
    html += `
              <div class="detail-section">
                  <h4>Camera & Capture</h4>
                  ${row.create_time ? `<div class="detail-row"><span class="label">Captured At:</span><span class="value">${escapeHtml(row.create_time)}</span></div>` : ""}
                  ${row.camera_make ? `<div class="detail-row"><span class="label">Camera Make:</span><span class="value">${escapeHtml(row.camera_make)}</span></div>` : ""}
                  ${row.camera_model ? `<div class="detail-row"><span class="label">Model:</span><span class="value">${escapeHtml(row.camera_model)}</span></div>` : ""}
              </div>
          `;
  }

  if (row.gps_latitude !== null && row.gps_longitude !== null) {
    const mapsUrl = `https://www.google.com/maps/search/?api=1&query=${row.gps_latitude},${row.gps_longitude}`;
    const gpsCoords = `${row.gps_latitude.toFixed(6)}, ${row.gps_longitude.toFixed(6)}`;
    html += `
              <div class="detail-section">
                  <h4>GPS Location</h4>
                  <div class="detail-row">
                      <span class="label">Coordinates:</span>
                      <span class="value-with-action">
                          <span class="value">${gpsCoords}</span>
                          <button class="copy-btn" onclick="copyValue(this)" aria-label="Copy coordinates">
                              <i data-lucide="copy" aria-hidden="true"></i>
                          </button>
                      </span>
                  </div>
                  <div class="detail-row">
                      <span class="label">Map Link:</span>
                      <span class="value">
                          <a href="${mapsUrl}" target="_blank" class="map-link">
                              View on Google Maps <i data-lucide="external-link" class="inline-icon" aria-hidden="true"></i>
                          </a>
                      </span>
                  </div>
              </div>
          `;
  }

  content.innerHTML = html;
  drawer.classList.add("open");
  drawer.setAttribute("aria-hidden", "false");
  document.getElementById("drawer-backdrop").classList.add("visible");
  lucide.createIcons({ root: drawer });
  document.addEventListener("keydown", handleDrawerKeydown);
  requestAnimationFrame(() => {
    document.getElementById("close-drawer-btn")?.focus();
  });
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

// ─── Chart.js resize-loop mitigation ───────────────────────────────────
// Chart.js attaches an internal ResizeObserver to every canvas when
// responsive:true is set. When the modal is closed, we destroy all charts
// to kill all observers and release memory.
//
// Strategy:
//   1. destroyAllCharts() on modal CLOSE → kills every observer immediately.
//   2. render*Charts() uses chart.update() when instances already exist.
//   3. switchModalTab() resizes active-tab charts on switch.
// ────────────────────────────────────────────────────────────────────────

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

async function toggleModal(show) {
  const modal = document.getElementById("insights-modal");
  if (show) {
    if (modal.classList.contains("open")) return;
    modal.classList.add("open");
    modal.setAttribute("aria-hidden", "false");

    modalSessionId++;
    const currentSession = modalSessionId;

    try {
      await loadChartJs();
      if (
        modalSessionId !== currentSession ||
        !modal.classList.contains("open")
      ) {
        return;
      }
      switchModalTab(activeModalTab); // recreates charts at current size
    } catch (err) {
      console.error("Failed to load Chart.js:", err);
      if (
        modalSessionId !== currentSession ||
        !modal.classList.contains("open")
      ) {
        return;
      }
    }

    // Clean up event listeners first to ensure we never double-register
    document.removeEventListener("keydown", handleModalKeydown);
    window.removeEventListener("click", handleModalBackdropClick);

    document.addEventListener("keydown", handleModalKeydown);
    window.addEventListener("click", handleModalBackdropClick);

    requestAnimationFrame(() => {
      if (
        modalSessionId === currentSession &&
        modal.classList.contains("open")
      ) {
        document.getElementById("close-modal-btn")?.focus();
      }
    });
  } else {
    if (!modal.classList.contains("open")) return;
    modalSessionId++; // Invalidate any ongoing loading session
    modal.classList.remove("open");
    modal.setAttribute("aria-hidden", "true");
    destroyAllCharts(); // stop observers before modal is hidden
    document.removeEventListener("keydown", handleModalKeydown);
    window.removeEventListener("click", handleModalBackdropClick);
    const returnFocus = modalReturnFocus;
    modalReturnFocus = null;
    if (returnFocus && typeof returnFocus.focus === "function") {
      returnFocus.focus();
    }
  }
}

// Switch between tabs inside insights modal
function switchModalTab(tabName) {
  activeModalTab = tabName;

  const imagesBtn = document.getElementById("tab-btn-images");
  const videosBtn = document.getElementById("tab-btn-videos");
  const imagesPane = document.getElementById("tab-pane-images");
  const videosPane = document.getElementById("tab-pane-videos");
  const isImages = tabName === "images";

  imagesBtn.classList.toggle("active", isImages);
  videosBtn.classList.toggle("active", !isImages);
  imagesBtn.setAttribute("aria-selected", isImages ? "true" : "false");
  videosBtn.setAttribute("aria-selected", isImages ? "false" : "true");
  imagesBtn.tabIndex = isImages ? 0 : -1;
  videosBtn.tabIndex = isImages ? -1 : 0;

  imagesPane.classList.toggle("active", isImages);
  videosPane.classList.toggle("active", !isImages);
  imagesPane.hidden = !isImages;
  videosPane.hidden = isImages;

  if (tabName === "images") {
    renderImageCharts();
  } else {
    renderVideoCharts();
  }
  resizeActiveCharts();
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

// Render Image-Specific Statistics
function renderImageCharts() {
  if (!statsData) return;
  const hasImages = statsData.num_images > 0;
  toggleChartPlaceholder(
    "wrapper-img-formats",
    hasImages,
    "No image data available in catalog",
  );
  toggleChartPlaceholder(
    "wrapper-img-sizes",
    hasImages,
    "No image data available in catalog",
  );

  // 1. IMAGE FORMATS
  if (hasImages && statsData.image_formats) {
    const labels = statsData.image_formats.map((f) => f.format.toUpperCase());
    const data = statsData.image_formats.map((f) => f.count);

    if (imgFormatChart) {
      imgFormatChart.data.labels = labels;
      imgFormatChart.data.datasets[0].data = data;
      imgFormatChart.update();
    } else {
      const ctx = document.getElementById("chart-img-formats").getContext("2d");
      imgFormatChart = new Chart(ctx, {
        type: "doughnut",
        data: {
          labels: labels,
          datasets: [
            {
              data: data,
              backgroundColor: [
                "#2b76db",
                "#34d399",
                "#fbbf24",
                "#f87171",
                "#a78bfa",
                "#38bdf8",
              ],
              borderWidth: 1,
              borderColor: "#ffffff",
            },
          ],
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { position: "right" } },
        },
      });
    }
  } else if (imgFormatChart) {
    imgFormatChart.destroy();
    imgFormatChart = null;
  }

  // 2. IMAGE SIZING DISTRIBUTION
  if (hasImages && statsData.image_sizes) {
    const tiers = statsData.image_sizes;
    const sizeTiers = {
      "< 1 MB": tiers.tier1,
      "1-5 MB": tiers.tier2,
      "5-10 MB": tiers.tier3,
      "10-25 MB": tiers.tier4,
      "> 25 MB": tiers.tier5,
    };

    if (imgSizeChart) {
      imgSizeChart.data.labels = Object.keys(sizeTiers);
      imgSizeChart.data.datasets[0].data = Object.values(sizeTiers);
      imgSizeChart.update();
    } else {
      const sizeCtx = document
        .getElementById("chart-img-sizes")
        .getContext("2d");
      imgSizeChart = new Chart(sizeCtx, {
        type: "bar",
        data: {
          labels: Object.keys(sizeTiers),
          datasets: [
            {
              data: Object.values(sizeTiers),
              backgroundColor: "#2b76db",
              borderRadius: 4,
            },
          ],
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { display: false } },
          scales: { y: { beginAtZero: true, ticks: { precision: 0 } } },
        },
      });
    }
  } else if (imgSizeChart) {
    imgSizeChart.destroy();
    imgSizeChart = null;
  }

  // 3. IMAGE CAMERA MODELS (TOP 5)
  const hasCameras = statsData.cameras && statsData.cameras.length > 0;
  toggleChartPlaceholder(
    "wrapper-img-cameras",
    hasCameras,
    "No camera model metadata found for images",
  );

  if (hasCameras) {
    const labels = statsData.cameras.map((c) => {
      const make = c.make || "";
      const model = c.model || "";
      if (!make && !model) return "Unknown";
      return make && model.startsWith(make) ? model : `${make} ${model}`;
    });
    const data = statsData.cameras.map((c) => c.count);

    if (imgCameraChart) {
      imgCameraChart.data.labels = labels;
      imgCameraChart.data.datasets[0].data = data;
      imgCameraChart.update();
    } else {
      const camCtx = document
        .getElementById("chart-img-cameras")
        .getContext("2d");
      imgCameraChart = new Chart(camCtx, {
        type: "bar",
        data: {
          labels: labels,
          datasets: [
            {
              data: data,
              backgroundColor: "#a78bfa",
              borderRadius: 4,
            },
          ],
        },
        options: {
          indexAxis: "y",
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { display: false } },
          scales: { x: { beginAtZero: true, ticks: { precision: 0 } } },
        },
      });
    }
  } else if (imgCameraChart) {
    imgCameraChart.destroy();
    imgCameraChart = null;
  }
}

// Render Video-Specific Statistics
function renderVideoCharts() {
  if (!statsData) return;
  const hasVideos = statsData.num_videos > 0;
  toggleChartPlaceholder(
    "wrapper-vid-formats",
    hasVideos,
    "No video data available in catalog",
  );
  toggleChartPlaceholder(
    "wrapper-vid-sizes",
    hasVideos,
    "No video data available in catalog",
  );
  toggleChartPlaceholder(
    "wrapper-vid-durations",
    hasVideos,
    "No video data available in catalog",
  );

  // 1. VIDEO FORMATS
  if (hasVideos && statsData.video_formats) {
    const labels = statsData.video_formats.map((f) => f.format.toUpperCase());
    const data = statsData.video_formats.map((f) => f.count);

    if (vidFormatChart) {
      vidFormatChart.data.labels = labels;
      vidFormatChart.data.datasets[0].data = data;
      vidFormatChart.update();
    } else {
      const ctx = document.getElementById("chart-vid-formats").getContext("2d");
      vidFormatChart = new Chart(ctx, {
        type: "doughnut",
        data: {
          labels: labels,
          datasets: [
            {
              data: data,
              backgroundColor: [
                "#2b76db",
                "#fbbf24",
                "#7c3aed",
                "#ec4899",
                "#64748b",
              ],
              borderWidth: 1,
              borderColor: "#ffffff",
            },
          ],
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { position: "right" } },
        },
      });
    }
  } else if (vidFormatChart) {
    vidFormatChart.destroy();
    vidFormatChart = null;
  }

  // 2. VIDEO SIZING
  if (hasVideos && statsData.video_sizes) {
    const tiers = statsData.video_sizes;
    const sizeTiers = {
      "< 10 MB": tiers.tier1,
      "10-100 MB": tiers.tier2,
      "100-500 MB": tiers.tier3,
      "500 MB-2 GB": tiers.tier4,
      "> 2 GB": tiers.tier5,
    };

    if (vidSizeChart) {
      vidSizeChart.data.labels = Object.keys(sizeTiers);
      vidSizeChart.data.datasets[0].data = Object.values(sizeTiers);
      vidSizeChart.update();
    } else {
      const sizeCtx = document
        .getElementById("chart-vid-sizes")
        .getContext("2d");
      vidSizeChart = new Chart(sizeCtx, {
        type: "bar",
        data: {
          labels: Object.keys(sizeTiers),
          datasets: [
            {
              data: Object.values(sizeTiers),
              backgroundColor: "#2b76db",
              borderRadius: 4,
            },
          ],
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { display: false } },
          scales: { y: { beginAtZero: true, ticks: { precision: 0 } } },
        },
      });
    }
  } else if (vidSizeChart) {
    vidSizeChart.destroy();
    vidSizeChart = null;
  }

  // 3. VIDEO DURATIONS
  if (hasVideos && statsData.video_durations) {
    const tiers = statsData.video_durations;
    const durationTiers = {
      "< 10s": tiers.tier1,
      "10s-1m": tiers.tier2,
      "1-5m": tiers.tier3,
      "5-15m": tiers.tier4,
      "> 15m": tiers.tier5,
    };

    if (vidDurationChart) {
      vidDurationChart.data.labels = Object.keys(durationTiers);
      vidDurationChart.data.datasets[0].data = Object.values(durationTiers);
      vidDurationChart.update();
    } else {
      const durCtx = document
        .getElementById("chart-vid-durations")
        .getContext("2d");
      vidDurationChart = new Chart(durCtx, {
        type: "bar",
        data: {
          labels: Object.keys(durationTiers),
          datasets: [
            {
              data: Object.values(durationTiers),
              backgroundColor: "#d97706",
              borderRadius: 4,
            },
          ],
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { display: false } },
          scales: { y: { beginAtZero: true, ticks: { precision: 0 } } },
        },
      });
    }
  } else if (vidDurationChart) {
    vidDurationChart.destroy();
    vidDurationChart = null;
  }
}

// Setup UI Event Listeners
document.addEventListener("DOMContentLoaded", () => {
  // Initial load: fetch stats, then fetch media
  fetchStats().then(() => fetchMedia());

  // Reload View button
  document.getElementById("refresh-btn").addEventListener("click", () => {
    currentPage = 1;
    fetchMedia({ refetchStats: true, showRefreshSpinner: true });
  });

  // Insights button
  document.getElementById("insights-btn").addEventListener("click", () => {
    modalReturnFocus = document.activeElement;
    toggleModal(true);
  });

  // Close details drawer
  document
    .getElementById("close-drawer-btn")
    .addEventListener("click", closeDrawer);

  // Close drawer on backdrop click
  document
    .getElementById("drawer-backdrop")
    .addEventListener("click", closeDrawer);

  // Escape key: close modal first, then drawer
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    const modal = document.getElementById("insights-modal");
    if (modal.classList.contains("open")) {
      toggleModal(false);
    } else {
      closeDrawer();
    }
  });

  // Close modal button
  document
    .getElementById("close-modal-btn")
    .addEventListener("click", () => toggleModal(false));

  document
    .querySelector(".modal-tabs")
    ?.addEventListener("keydown", handleModalTablistKeydown);

  document
    .getElementById("tab-btn-images")
    ?.addEventListener("click", () => switchModalTab("images"));
  document
    .getElementById("tab-btn-videos")
    ?.addEventListener("click", () => switchModalTab("videos"));

  // Filter changes
  document
    .getElementById("filter-format")
    .addEventListener("change", triggerFilterRefresh);
  document.getElementById("filter-type").addEventListener("change", () => {
    updateFormatFilterOptions();
    triggerFilterRefresh();
  });

  document.querySelectorAll("[data-date-preset]").forEach((btn) => {
    btn.addEventListener("click", () => {
      applyDatePreset(btn.getAttribute("data-date-preset"));
      triggerFilterRefresh();
    });
  });

  document.querySelectorAll("[data-size-min-mb]").forEach((btn) => {
    btn.addEventListener("click", () => {
      applySizePreset(parseInt(btn.getAttribute("data-size-min-mb"), 10));
      triggerFilterRefresh();
    });
  });

  let dateFilterTimeout;
  ["filter-date-from", "filter-date-to"].forEach((id) => {
    const el = document.getElementById(id);
    const handleDateInput = () => {
      clearDatePresetActive();
      clearTimeout(dateFilterTimeout);
      dateFilterTimeout = setTimeout(triggerFilterRefresh, FILTER_DEBOUNCE_MS);
    };
    el.addEventListener("input", handleDateInput);
    el.addEventListener("change", handleDateInput);
  });

  let sizeFilterTimeout;
  ["filter-size-min", "filter-size-max"].forEach((id) => {
    document.getElementById(id).addEventListener("input", () => {
      clearSizePresetActive();
      clearTimeout(sizeFilterTimeout);
      sizeFilterTimeout = setTimeout(triggerFilterRefresh, FILTER_DEBOUNCE_MS);
    });
  });

  document.getElementById("clear-filters-btn").addEventListener("click", () => {
    clearAdvancedFilters();
    updateFormatFilterOptions();
    currentPage = 1;
    fetchMedia();
  });

  document.getElementById("active-filters")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".filter-chip-dismiss");
    if (!btn) return;
    const key = btn.closest(".filter-chip")?.getAttribute("data-filter-key");
    if (key) removeFilterChip(key);
  });

  document.getElementById("media-tbody")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".empty-state-action");
    if (btn) {
      e.stopPropagation();
      handleEmptyStateAction(btn);
      return;
    }

    const tr = e.target.closest("tr[data-row-index]");
    if (!tr) return;
    const idx = parseInt(tr.dataset.rowIndex, 10);
    if (!Number.isNaN(idx) && mediaData[idx]) {
      showDetails(mediaData[idx], tr);
    }
  });

  document.getElementById("media-tbody")?.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" && e.key !== " ") return;
    const tr = e.target.closest("tr[data-row-index]");
    if (!tr) return;
    e.preventDefault();
    const idx = parseInt(tr.dataset.rowIndex, 10);
    if (!Number.isNaN(idx) && mediaData[idx]) {
      showDetails(mediaData[idx], tr);
    }
  });

  // Search input with 500ms debounce
  let searchTimeout;
  document.getElementById("search-input").addEventListener("input", () => {
    clearTimeout(searchTimeout);
    searchTimeout = setTimeout(triggerFilterRefresh, FILTER_DEBOUNCE_MS);
  });

  // Pagination buttons
  document.getElementById("prev-page-btn").addEventListener("click", () => {
    if (currentPage > 1) {
      currentPage--;
      fetchMedia({ showSkeleton: false });
    }
  });
  document.getElementById("next-page-btn").addEventListener("click", () => {
    const totalPages = Math.ceil(totalRecords / pageSize) || 1;
    if (currentPage < totalPages) {
      currentPage++;
      fetchMedia({ showSkeleton: false });
    }
  });
  document
    .getElementById("page-size-select")
    .addEventListener("change", (e) => {
      pageSize = parseInt(e.target.value, 10);
      currentPage = 1;
      fetchMedia({ showSkeleton: false });
    });

  // Sort headers
  document.querySelectorAll("#media-table th").forEach((th) => {
    th.addEventListener("click", () => {
      const key = th.getAttribute("data-sort");
      if (!key) return;

      if (sortConfig.key === key) {
        sortConfig.direction = sortConfig.direction === "asc" ? "desc" : "asc";
      } else {
        sortConfig.key = key;
        sortConfig.direction = "asc";
      }

      // Update UI sorting indicator
      document
        .querySelectorAll("#media-table th")
        .forEach((el) => el.classList.remove("sort-asc", "sort-desc"));
      th.classList.add(
        sortConfig.direction === "asc" ? "sort-asc" : "sort-desc",
      );
      updateSortAriaIndicators();

      currentPage = 1;
      fetchMedia({ showSkeleton: false });
    });
  });

  updateSortAriaIndicators();

  const initialSortTh = document.querySelector(
    `#media-table th[data-sort="${sortConfig.key}"]`,
  );
  if (initialSortTh) {
    initialSortTh.classList.add(
      sortConfig.direction === "asc" ? "sort-asc" : "sort-desc",
    );
  }

  // Initialize Lucide Icons for static elements
  lucide.createIcons();

  updateDatePresetActiveState();
  updateSizePresetActiveState();
  initMoreFiltersToggle();
});
