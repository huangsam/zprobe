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
  if (activeLayout === "grid") {
    renderGrid();
  } else {
    renderTable();
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
