let activeEmptyStateActions = [];

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
    case "last7": {
      const last7 = new Date(today);
      last7.setDate(today.getDate() - 7);
      return { from: toIsoDate(last7), to: toIsoDate(now) };
    }
    case "this-month": {
      const startOfMonth = new Date(today.getFullYear(), today.getMonth(), 1);
      return { from: toIsoDate(startOfMonth), to: toIsoDate(now) };
    }
    case "this-year": {
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

// Populate format filter options dynamically based on selected type
function updateFormatFilterOptions() {
  const select = document.getElementById("filter-format");
  if (!select) return;

  const typeFilter = document.getElementById("filter-type").value;
  const allLabel =
    typeFilter === "image"
      ? "All Image Formats"
      : typeFilter === "video"
        ? "All Video Formats"
        : "All Formats";

  if (!statsData) {
    select.innerHTML = `<option value="">${allLabel}</option>`;
    return;
  }
  const formats = new Set();
  const includeImages = typeFilter === "" || typeFilter === "image";
  const includeVideos = typeFilter === "" || typeFilter === "video";

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
