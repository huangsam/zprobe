// Setup UI Event Listeners
document.addEventListener("DOMContentLoaded", () => {
  // Initialize theme toggle state and listeners
  updateThemeToggleButton();
  document
    .getElementById("theme-toggle-btn")
    ?.addEventListener("click", toggleTheme);

  if (window.matchMedia) {
    window
      .matchMedia("(prefers-color-scheme: dark)")
      .addEventListener("change", () => {
        updateThemeToggleButton();
        if (typeof refreshChartsTheme === "function") {
          refreshChartsTheme();
        }
      });
  }

  window.addEventListener("storage", (e) => {
    if (e.key === "color-scheme") {
      applyThemeState(e.newValue);
    }
  });

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

  // Details drawer navigation and close handlers
  document
    .getElementById("drawer-prev-btn")
    ?.addEventListener("click", () => navigateDrawer(-1));
  document
    .getElementById("drawer-next-btn")
    ?.addEventListener("click", () => navigateDrawer(1));
  document
    .getElementById("close-drawer-btn")
    ?.addEventListener("click", closeDrawer);

  // Close drawer on backdrop click
  document
    .getElementById("drawer-backdrop")
    ?.addEventListener("click", closeDrawer);

  // Escape key: close lightbox first, then sort modal, then shortcuts modal, then insights modal, then drawer
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    const lightboxModal = document.getElementById("lightbox-modal");
    const shortcutsModal = document.getElementById("shortcuts-modal");
    const sortModal = document.getElementById("sort-modal");
    const modal = document.getElementById("insights-modal");
    if (lightboxModal && lightboxModal.classList.contains("open")) {
      closeLightbox();
    } else if (shortcutsModal && shortcutsModal.classList.contains("open")) {
      toggleShortcutsModal(false);
    } else if (sortModal && sortModal.classList.contains("open")) {
      toggleSortModal(false);
    } else if (modal && modal.classList.contains("open")) {
      toggleModal(false);
    } else if (
      document.getElementById("details-drawer")?.classList.contains("open")
    ) {
      closeDrawer();
    } else if (selectedIndex !== -1) {
      setSelectedIndex(-1);
    }
  });

  // Global search shortcuts: '/' and Cmd+K / Ctrl+K to jump to search
  document.addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
      e.preventDefault();
      const searchEl = document.getElementById("search-input");
      if (searchEl) {
        searchEl.focus();
        searchEl.select();
      }
      return;
    }

    if (e.key === "/" && !e.metaKey && !e.ctrlKey && !e.altKey) {
      const target = e.target;
      const isInput =
        target.tagName === "INPUT" ||
        target.tagName === "TEXTAREA" ||
        target.tagName === "SELECT" ||
        target.isContentEditable;
      if (!isInput) {
        e.preventDefault();
        const searchEl = document.getElementById("search-input");
        if (searchEl) {
          searchEl.focus();
          searchEl.select();
        }
      }
    }
  });

  // Sort modal toggle & close handlers
  document.getElementById("sort-modal-btn")?.addEventListener("click", () => {
    toggleSortModal(true);
  });

  document
    .getElementById("close-sort-modal-btn")
    ?.addEventListener("click", () => toggleSortModal(false));

  // Sort field radio button change handlers
  document.querySelectorAll('input[name="sort-field"]').forEach((radio) => {
    radio.addEventListener("change", (e) => {
      if (e.target.checked) {
        sortConfig.key = e.target.value;
        updateSortAriaIndicators();
        currentPage = 1;
        fetchMedia({ showSkeleton: false });
      }
    });
  });

  // Sort direction toggle button handlers
  const handleDirToggle = (dir) => {
    if (sortConfig.direction === dir) return;
    sortConfig.direction = dir;
    updateSortAriaIndicators();
    currentPage = 1;
    fetchMedia({ showSkeleton: false });
  };

  document
    .getElementById("sort-dir-asc-btn")
    ?.addEventListener("click", () => handleDirToggle("asc"));
  document
    .getElementById("sort-dir-desc-btn")
    ?.addEventListener("click", () => handleDirToggle("desc"));

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

  document
    .getElementById("clear-filters-btn")
    ?.addEventListener("click", () => {
      clearAdvancedFilters();
      updateFormatFilterOptions();
      currentPage = 1;
      fetchMedia();
      showToast("Filters cleared", "info");
    });

  document
    .getElementById("close-filter-modal-btn")
    ?.addEventListener("click", () => toggleFilterModal(false));

  document
    .getElementById("apply-advanced-filters-btn")
    ?.addEventListener("click", () => toggleFilterModal(false));

  document
    .getElementById("reset-advanced-filters-btn")
    ?.addEventListener("click", resetAdvancedFilterInputs);

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
      setSelectedIndex(idx, { scrollToView: false });
      showDetails(mediaData[idx], tr);
    }
  });

  // Keep selection in sync with Tab focus so a focused row always shows the selected style
  document.getElementById("media-tbody")?.addEventListener("focusin", (e) => {
    const tr = e.target.closest("tr[data-row-index]");
    if (!tr) return;
    const idx = parseInt(tr.dataset.rowIndex, 10);
    if (!Number.isNaN(idx) && idx !== selectedIndex && mediaData[idx]) {
      setSelectedIndex(idx, { scrollToView: false });
    }
  });

  document.getElementById("media-tbody")?.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" && e.key !== " ") return;
    const tr = e.target.closest("tr[data-row-index]");
    if (!tr) return;
    e.preventDefault();
    const idx = parseInt(tr.dataset.rowIndex, 10);
    if (!Number.isNaN(idx) && mediaData[idx]) {
      setSelectedIndex(idx, { scrollToView: false });
      if (e.key === " ") {
        openLightbox(idx);
      } else {
        showDetails(mediaData[idx], tr);
      }
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
      setSelectedIndex(idx, { scrollToView: false });
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
      setSelectedIndex(idx, { scrollToView: false });
      if (e.key === " ") {
        openLightbox(idx);
      } else {
        showDetails(mediaData[idx], card);
      }
    }
  });

  // View toggle button click listeners
  document.getElementById("view-list-btn")?.addEventListener("click", () => {
    setViewLayout("list");
    showToast("Switched to List View", "info", 1800);
  });

  document.getElementById("view-grid-btn")?.addEventListener("click", () => {
    setViewLayout("grid");
    showToast("Switched to Grid View", "info", 1800);
  });

  // Search input with 500ms debounce, quick-clear, and Escape handling
  let searchTimeout;
  const searchInput = document.getElementById("search-input");
  const searchClearBtn = document.getElementById("search-clear-btn");

  if (searchInput) {
    searchInput.addEventListener("input", () => {
      updateSearchInputControls();
      clearTimeout(searchTimeout);
      searchTimeout = setTimeout(triggerFilterRefresh, FILTER_DEBOUNCE_MS);
    });

    searchInput.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        if (searchInput.value) {
          e.stopPropagation();
          searchInput.value = "";
          updateSearchInputControls();
          triggerFilterRefresh();
        } else {
          searchInput.blur();
        }
      }
    });
  }

  if (searchClearBtn) {
    searchClearBtn.addEventListener("click", () => {
      if (searchInput) {
        searchInput.value = "";
        updateSearchInputControls();
        triggerFilterRefresh();
        searchInput.focus();
      }
    });
  }

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
  const handleSortClick = (th) => {
    const key = th.getAttribute("data-sort");
    if (!key) return;

    if (sortConfig.key === key) {
      sortConfig.direction = sortConfig.direction === "asc" ? "desc" : "asc";
    } else {
      sortConfig.key = key;
      sortConfig.direction = "asc";
    }

    updateSortAriaIndicators();

    currentPage = 1;
    fetchMedia({ showSkeleton: false });
  };

  document.querySelectorAll("#media-table th").forEach((th) => {
    th.addEventListener("click", () => handleSortClick(th));
    th.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        handleSortClick(th);
      }
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
  updateSearchInputControls();

  // Shortcuts modal toggle & close handlers
  document.getElementById("shortcuts-btn")?.addEventListener("click", () => {
    toggleShortcutsModal(true);
  });

  document
    .getElementById("close-shortcuts-modal-btn")
    ?.addEventListener("click", () => toggleShortcutsModal(false));

  // Lightbox button listeners
  document
    .getElementById("close-lightbox-btn")
    ?.addEventListener("click", closeLightbox);
  document
    .getElementById("lightbox-prev-btn")
    ?.addEventListener("click", () => navigateLightbox(-1));
  document
    .getElementById("lightbox-next-btn")
    ?.addEventListener("click", () => navigateLightbox(1));
  document
    .getElementById("lightbox-zoom-btn")
    ?.addEventListener("click", toggleLightboxZoom);

  // Global catalog keyboard navigation
  document.addEventListener("keydown", (e) => {
    // Skip if user is in an input or any modal/drawer is open
    if (isInputFocused() || isAnyModalOrDrawerOpen()) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;

    if (e.key === " ") {
      if (mediaData.length > 0) {
        e.preventDefault();
        openLightbox(selectedIndex >= 0 ? selectedIndex : 0);
      }
      return;
    }

    if (e.key === "?" || (e.shiftKey && e.key === "/")) {
      e.preventDefault();
      toggleShortcutsModal(true);
      return;
    }

    if (e.key.toLowerCase() === "r") {
      e.preventDefault();
      currentPage = 1;
      fetchMedia({ refetchStats: true, showRefreshSpinner: true });
      showToast("Catalog reloaded", "info");
      return;
    }

    if (e.key.toLowerCase() === "t") {
      e.preventDefault();
      toggleTheme();
      return;
    }

    if (e.key.toLowerCase() === "c") {
      if (selectedIndex >= 0 && selectedIndex < mediaData.length) {
        e.preventDefault();
        const row = mediaData[selectedIndex];
        copyToClipboard(row.path, {
          classList: { add: () => {}, remove: () => {} },
        });
      }
      return;
    }

    if (e.key === "[") {
      if (currentPage > 1) {
        e.preventDefault();
        currentPage--;
        fetchMedia({ showSkeleton: false });
        setSelectedIndex(0);
      } else {
        showToast("Already on the first page", "info", 1500);
      }
      return;
    }

    if (e.key === "]") {
      const totalPages = Math.ceil(totalRecords / pageSize) || 1;
      if (currentPage < totalPages) {
        e.preventDefault();
        currentPage++;
        fetchMedia({ showSkeleton: false });
        setSelectedIndex(0);
      } else {
        showToast("Already on the last page", "info", 1500);
      }
      return;
    }

    const activeLayout =
      document
        .getElementById("catalog-table")
        ?.getAttribute("data-view-layout") || "list";

    if (e.key === "Home") {
      if (mediaData.length > 0) {
        e.preventDefault();
        setSelectedIndex(0, { focus: true });
      }
      return;
    }

    if (e.key === "End") {
      if (mediaData.length > 0) {
        e.preventDefault();
        setSelectedIndex(mediaData.length - 1, { focus: true });
      }
      return;
    }

    if (e.key === "ArrowDown" || e.key === "j") {
      if (mediaData.length === 0) return;
      e.preventDefault();
      if (activeLayout === "grid") {
        const cols = getGridColumnCount();
        const next =
          selectedIndex === -1
            ? 0
            : Math.min(mediaData.length - 1, selectedIndex + cols);
        setSelectedIndex(next, { focus: true });
      } else {
        const next =
          selectedIndex === -1
            ? 0
            : Math.min(mediaData.length - 1, selectedIndex + 1);
        setSelectedIndex(next, { focus: true });
      }
      return;
    }

    if (e.key === "ArrowUp" || e.key === "k") {
      if (mediaData.length === 0) return;
      e.preventDefault();
      if (activeLayout === "grid") {
        const cols = getGridColumnCount();
        const prev =
          selectedIndex === -1 ? 0 : Math.max(0, selectedIndex - cols);
        setSelectedIndex(prev, { focus: true });
      } else {
        const prev = selectedIndex === -1 ? 0 : Math.max(0, selectedIndex - 1);
        setSelectedIndex(prev, { focus: true });
      }
      return;
    }

    if (activeLayout === "grid") {
      if (e.key === "ArrowRight" || e.key === "l") {
        if (mediaData.length === 0) return;
        e.preventDefault();
        const next =
          selectedIndex === -1
            ? 0
            : Math.min(mediaData.length - 1, selectedIndex + 1);
        setSelectedIndex(next, { focus: true });
        return;
      }
      if (e.key === "ArrowLeft" || e.key === "h") {
        if (mediaData.length === 0) return;
        e.preventDefault();
        const prev = selectedIndex === -1 ? 0 : Math.max(0, selectedIndex - 1);
        setSelectedIndex(prev, { focus: true });
        return;
      }
    }

    if (e.key === "Enter") {
      if (selectedIndex >= 0 && selectedIndex < mediaData.length) {
        e.preventDefault();
        const activeEl =
          activeLayout === "grid"
            ? document.querySelector(
                `#media-grid .grid-card[data-row-index="${selectedIndex}"]`,
              )
            : document.querySelector(
                `#media-tbody tr[data-row-index="${selectedIndex}"]`,
              );
        showDetails(mediaData[selectedIndex], activeEl);
      }
      return;
    }
  });
});

// Shortcuts modal handlers
function handleShortcutsModalKeydown(e) {
  const modal = document.getElementById("shortcuts-modal");
  if (!modal || !modal.classList.contains("open")) return;
  if (e.key === "Escape") {
    e.preventDefault();
    toggleShortcutsModal(false);
    return;
  }
  trapFocus(e, modal);
}

function handleShortcutsModalBackdropClick(e) {
  const modal = document.getElementById("shortcuts-modal");
  if (e.target === modal) {
    toggleShortcutsModal(false);
  }
}

function toggleShortcutsModal(show) {
  const modal = document.getElementById("shortcuts-modal");
  const toggleBtn = document.getElementById("shortcuts-btn");
  if (!modal) return;

  if (show) {
    if (modal.classList.contains("open")) return;
    shortcutsModalReturnFocus = document.activeElement;
    modal.classList.add("open");
    modal.removeAttribute("inert");
    modal.setAttribute("aria-hidden", "false");
    toggleBtn?.setAttribute("aria-expanded", "true");

    document.removeEventListener("keydown", handleShortcutsModalKeydown);
    window.removeEventListener("click", handleShortcutsModalBackdropClick);

    document.addEventListener("keydown", handleShortcutsModalKeydown);
    window.addEventListener("click", handleShortcutsModalBackdropClick);

    requestAnimationFrame(() => {
      document.getElementById("close-shortcuts-modal-btn")?.focus();
    });
  } else {
    if (!modal.classList.contains("open")) return;
    modal.classList.remove("open");
    modal.setAttribute("inert", "");
    modal.setAttribute("aria-hidden", "true");
    toggleBtn?.setAttribute("aria-expanded", "false");

    document.removeEventListener("keydown", handleShortcutsModalKeydown);
    window.removeEventListener("click", handleShortcutsModalBackdropClick);

    const returnFocus = shortcutsModalReturnFocus;
    shortcutsModalReturnFocus = null;
    if (returnFocus && typeof returnFocus.focus === "function") {
      returnFocus.focus();
    }
  }
}
