// Render the grid layout cards
function renderGrid() {
  const grid = document.getElementById("media-grid");
  if (!grid) return;

  if (mediaData.length === 0) {
    // Prevent prematurely showing the empty state during initial page hydration
    if (!initialFetchComplete) {
      renderSkeletons();
      return;
    }
    grid.innerHTML = `<div class="empty-state" style="grid-column: 1 / -1">${buildEmptyStateHtml()}</div>`;
    return;
  }

  const searchInput = document.getElementById("search-input");
  const query = searchInput ? searchInput.value : "";

  grid.innerHTML = "";
  mediaData.forEach((row, index) => {
    const card = document.createElement("div");
    card.className = "grid-card";
    if (row.has_animated) {
      card.classList.add("has-animated");
    }
    card.tabIndex = 0;
    card.setAttribute("role", "button");
    card.dataset.rowIndex = String(index);

    const fileBase = row.path.split("/").pop();
    const dirPath = row.path.substring(0, row.path.lastIndexOf("/"));

    card.setAttribute("aria-label", `View details for ${fileBase}`);

    const isVid = isVideo(row);
    const thumbHtml = renderThumbnailHtml(row, "", fileBase);

    const mediaClass = row.has_animated
      ? "grid-card-media has-animated"
      : "grid-card-media";

    // Format badge
    const formatBadge = row.format
      ? `<span class="grid-card-badge">${highlightMatch((row.format || "").toUpperCase(), query)}</span>`
      : "";

    // Permanent Video Badge with duration overlay if available
    let videoBadge = "";
    if (isVid) {
      const durText = formatDigitalDuration(row.duration_sec);
      videoBadge = `
        <div class="grid-card-video-badge" aria-hidden="true">
          <i data-lucide="video"></i>
          ${durText ? `<span>${durText}</span>` : ""}
        </div>
      `;
    }

    card.innerHTML = `
      <div class="${escapeHtml(mediaClass)}">
        ${thumbHtml}
        ${formatBadge}
        ${videoBadge}
      </div>
      <div class="grid-card-info">
        <span class="grid-card-title">${highlightMatch(fileBase, query)}</span>
        <span class="grid-card-meta" title="${escapeHtml(dirPath)}">${highlightMatch(dirPath, query)}</span>
      </div>
    `;

    grid.appendChild(card);
  });

  if (
    typeof lucide !== "undefined" &&
    typeof lucide.createIcons === "function"
  ) {
    lucide.createIcons({ root: grid });
  }
}
