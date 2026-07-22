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
    statsData = null;
    const metricIds = [
      "stat-total-files",
      "stat-total-size",
      "stat-images",
      "stat-videos",
    ];
    metricIds.forEach((id) => {
      const el = document.getElementById(id);
      if (el) {
        el.textContent = "Error";
        el.title = "Failed to load stats";
        el.classList.add("error-state");
      }
    });
    const summary = document.getElementById("stats-live-summary");
    if (summary) {
      summary.textContent = "Failed to load catalog stats";
    }
    updateFormatFilterOptions();
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
  const gridContainer = document.getElementById("media-grid");
  if (gridContainer) gridContainer.setAttribute("aria-busy", "true");
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
    initialFetchComplete = true;

    const totalPages = Math.ceil(totalRecords / pageSize) || 1;
    if (currentPage > totalPages) {
      currentPage = totalPages;
      return fetchMedia({
        refetchStats: false,
        showSkeleton,
        showRefreshSpinner,
      });
    }

    renderMediaCatalog();
    updatePaginationControls();
    updateActiveFilterChips();
  } catch (err) {
    if (err.name === "AbortError") return;
    console.error(err);
    initialFetchComplete = true;
    if (tbody) {
      tbody.innerHTML = `<tr><td colspan="5" class="error-state">Failed to load media catalog: ${err.message}</td></tr>`;
    }
    const grid = document.getElementById("media-grid");
    if (grid) {
      grid.innerHTML = `<div class="error-state" style="grid-column: 1 / -1">Failed to load media catalog: ${err.message}</div>`;
    }
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
        const gridContainer = document.getElementById("media-grid");
        if (gridContainer) gridContainer.setAttribute("aria-busy", "false");
        currentFetchController = null;
      }, remainingTime);
    }
  }
}
