// Helper: Render pulsing skeleton loading rows
function renderSkeletons() {
  const tbody = document.getElementById("media-tbody");
  if (tbody) {
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

  const grid = document.getElementById("media-grid");
  if (grid) {
    let html = "";
    for (let i = 0; i < 8; i++) {
      html += `
        <div class="grid-skeleton-card">
          <div class="grid-skeleton-media"></div>
          <div class="grid-skeleton-info">
            <div class="grid-skeleton-text title"></div>
            <div class="grid-skeleton-text subtitle"></div>
          </div>
        </div>
      `;
    }
    grid.innerHTML = html;
  }
}

// Render the table rows
function renderTable() {
  const tbody = document.getElementById("media-tbody");

  if (mediaData.length === 0) {
    // Prevent prematurely showing the empty state during initial page hydration
    if (!initialFetchComplete) {
      renderSkeletons();
      return;
    }
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
    if (row.has_animated) {
      tr.classList.add("has-animated");
    }

    const dims =
      row.width && row.height
        ? `${escapeHtml(String(row.width))} &times; ${escapeHtml(String(row.height))}`
        : "—";
    const fileBase = row.path.split("/").pop();
    const dirPath = row.path.substring(0, row.path.lastIndexOf("/"));

    tr.setAttribute("aria-label", `View details for ${fileBase}`);

    const thumbHtml = renderThumbnailHtml(row, "row-thumbnail", "Thumbnail");
    // Add has-animated marker class so CSS hover rule targets only these rows.
    const wrapperClass = row.has_animated
      ? "thumbnail-wrapper has-animated"
      : "thumbnail-wrapper";

    tr.innerHTML = `
              <td class="file-path-cell">
                  <div class="file-path-content">
                      <div class="${escapeHtml(wrapperClass)}">
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
  if (
    typeof lucide !== "undefined" &&
    typeof lucide.createIcons === "function"
  ) {
    lucide.createIcons({ root: tbody });
  }
}

// Master rendering function determined by view mode preference
function renderMediaCatalog() {
  const activeLayout = localStorage.getItem("zprobe_view_layout") || "list";
  const updateDOM = () => {
    if (activeLayout === "grid") {
      renderGrid();
    } else {
      renderTable();
    }
  };

  if (document.startViewTransition && initialFetchComplete) {
    document.startViewTransition(updateDOM);
  } else {
    updateDOM();
  }
}

// Set active view layout and switch containers
function setViewLayout(layout) {
  const viewListBtn = document.getElementById("view-list-btn");
  const viewGridBtn = document.getElementById("view-grid-btn");
  const catalogTable = document.getElementById("catalog-table");

  if (!catalogTable) return;

  const updateDOM = () => {
    localStorage.setItem("zprobe_view_layout", layout);
    catalogTable.setAttribute("data-view-layout", layout);

    if (layout === "grid") {
      viewListBtn?.classList.remove("active");
      viewListBtn?.setAttribute("aria-pressed", "false");
      viewGridBtn?.classList.add("active");
      viewGridBtn?.setAttribute("aria-pressed", "true");
      renderGrid();
    } else {
      viewListBtn?.classList.add("active");
      viewListBtn?.setAttribute("aria-pressed", "true");
      viewGridBtn?.classList.remove("active");
      viewGridBtn?.setAttribute("aria-pressed", "false");
      renderTable();
    }
  };

  if (document.startViewTransition) {
    document.startViewTransition(updateDOM);
  } else {
    updateDOM();
  }
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

// Synchronize UI elements in the Sort Modal (radio inputs, direction buttons, contextual labels)
function updateSortModalUI() {
  const radio = document.querySelector(
    `input[name="sort-field"][value="${sortConfig.key}"]`,
  );
  if (radio) radio.checked = true;

  const ascBtn = document.getElementById("sort-dir-asc-btn");
  const descBtn = document.getElementById("sort-dir-desc-btn");

  if (ascBtn && descBtn) {
    if (sortConfig.direction === "asc") {
      ascBtn.classList.add("active");
      ascBtn.setAttribute("aria-pressed", "true");
      descBtn.classList.remove("active");
      descBtn.setAttribute("aria-pressed", "false");
    } else {
      descBtn.classList.add("active");
      descBtn.setAttribute("aria-pressed", "true");
      ascBtn.classList.remove("active");
      ascBtn.setAttribute("aria-pressed", "false");
    }
  }

  // Contextual labels for sort direction buttons
  const ascLabel = document.getElementById("sort-dir-asc-label");
  const descLabel = document.getElementById("sort-dir-desc-label");
  if (ascLabel && descLabel) {
    switch (sortConfig.key) {
      case "create_time":
        ascLabel.textContent = "Ascending (Oldest)";
        descLabel.textContent = "Descending (Newest)";
        break;
      case "size":
        ascLabel.textContent = "Ascending (Smallest)";
        descLabel.textContent = "Descending (Largest)";
        break;
      case "duration_sec":
        ascLabel.textContent = "Ascending (Shortest)";
        descLabel.textContent = "Descending (Longest)";
        break;
      case "path":
      case "format":
        ascLabel.textContent = "Ascending (A–Z)";
        descLabel.textContent = "Descending (Z–A)";
        break;
      case "dimensions":
        ascLabel.textContent = "Ascending (Smallest)";
        descLabel.textContent = "Descending (Largest)";
        break;
      default:
        ascLabel.textContent = "Ascending";
        descLabel.textContent = "Descending";
        break;
    }
  }

  // Update header sort button icon
  const sortBtnIcon = document.querySelector("#sort-modal-btn .btn-icon");
  if (sortBtnIcon) {
    const newIconName =
      sortConfig.direction === "asc"
        ? "arrow-up-narrow-wide"
        : "arrow-down-wide-narrow";
    if (sortBtnIcon.getAttribute("data-lucide") !== newIconName) {
      sortBtnIcon.setAttribute("data-lucide", newIconName);
      if (
        typeof lucide !== "undefined" &&
        typeof lucide.createIcons === "function"
      ) {
        lucide.createIcons({ root: document.getElementById("sort-modal-btn") });
      }
    }
  }
}

// Update ARIA attributes and classes on table headers & sort controls to reflect current sort state
function updateSortAriaIndicators() {
  document.querySelectorAll("#media-table th[data-sort]").forEach((th) => {
    const key = th.getAttribute("data-sort");
    th.classList.remove("sort-asc", "sort-desc");
    if (key === sortConfig.key) {
      th.setAttribute(
        "aria-sort",
        sortConfig.direction === "asc" ? "ascending" : "descending",
      );
      th.classList.add(
        sortConfig.direction === "asc" ? "sort-asc" : "sort-desc",
      );
    } else {
      th.setAttribute("aria-sort", "none");
    }
  });

  updateSortModalUI();
}

function handleSortModalBackdropClick(event) {
  const modal = document.getElementById("sort-modal");
  if (event.target === modal) {
    toggleSortModal(false);
  }
}

function handleSortModalKeydown(event) {
  const modal = document.getElementById("sort-modal");
  if (!modal || !modal.classList.contains("open")) return;

  if (event.key === "Escape") {
    event.preventDefault();
    event.stopPropagation();
    toggleSortModal(false);
    return;
  }

  if (event.key === "Tab") {
    const focusables = modal.querySelectorAll(
      'button:not([disabled]), input[type="radio"]:not([disabled]), [tabindex]:not([tabindex="-1"])',
    );
    if (focusables.length === 0) return;
    const first = focusables[0];
    const last = focusables[focusables.length - 1];

    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }
}

function toggleSortModal(show) {
  const modal = document.getElementById("sort-modal");
  const sortBtn = document.getElementById("sort-modal-btn");
  if (!modal) return;

  if (show) {
    if (modal.classList.contains("open")) return;
    sortModalReturnFocus = document.activeElement;
    updateSortModalUI();
    modal.classList.add("open");
    modal.removeAttribute("inert");
    modal.setAttribute("aria-hidden", "false");
    sortBtn?.setAttribute("aria-expanded", "true");

    document.removeEventListener("keydown", handleSortModalKeydown);
    window.removeEventListener("click", handleSortModalBackdropClick);

    document.addEventListener("keydown", handleSortModalKeydown);
    window.addEventListener("click", handleSortModalBackdropClick);

    requestAnimationFrame(() => {
      const activeRadio = modal.querySelector(
        'input[name="sort-field"]:checked',
      );
      if (activeRadio) {
        activeRadio.focus();
      } else {
        document.getElementById("close-sort-modal-btn")?.focus();
      }
    });
  } else {
    if (!modal.classList.contains("open")) return;
    modal.classList.remove("open");
    modal.setAttribute("inert", "");
    modal.setAttribute("aria-hidden", "true");
    sortBtn?.setAttribute("aria-expanded", "false");

    document.removeEventListener("keydown", handleSortModalKeydown);
    window.removeEventListener("click", handleSortModalBackdropClick);

    const returnFocus = sortModalReturnFocus;
    sortModalReturnFocus = null;
    if (returnFocus && typeof returnFocus.focus === "function") {
      returnFocus.focus();
    }
  }
}
