// Setup UI Event Listeners
document.addEventListener("DOMContentLoaded", () => {
  // Initialize view layout
  const activeView = localStorage.getItem("zprobe_view_layout") || "list";
  setViewLayout(activeView);

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

  // Grid view click and keydown handlers
  document.getElementById("media-grid")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".empty-state-action");
    if (btn) {
      e.stopPropagation();
      handleEmptyStateAction(btn);
      return;
    }

    const card = e.target.closest(".grid-card[data-row-index]");
    if (!card) return;
    const idx = parseInt(card.dataset.rowIndex, 10);
    if (!Number.isNaN(idx) && mediaData[idx]) {
      showDetails(mediaData[idx], card);
    }
  });

  document.getElementById("media-grid")?.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" && e.key !== " ") return;
    const card = e.target.closest(".grid-card[data-row-index]");
    if (!card) return;
    e.preventDefault();
    const idx = parseInt(card.dataset.rowIndex, 10);
    if (!Number.isNaN(idx) && mediaData[idx]) {
      showDetails(mediaData[idx], card);
    }
  });

  // View toggle button click listeners
  document.getElementById("view-list-btn")?.addEventListener("click", () => {
    setViewLayout("list");
  });

  document.getElementById("view-grid-btn")?.addEventListener("click", () => {
    setViewLayout("grid");
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
  if (
    typeof lucide !== "undefined" &&
    typeof lucide.createIcons === "function"
  ) {
    lucide.createIcons();
  }

  updateDatePresetActiveState();
  updateSizePresetActiveState();
  initMoreFiltersToggle();
});
