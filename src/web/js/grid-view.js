// Render the grid layout cards
function renderGrid() {
  const grid = document.getElementById("media-grid");
  if (!grid) return;

  if (mediaData.length === 0) {
    grid.innerHTML = `<div class="empty-state" style="grid-column: 1 / -1">${buildEmptyStateHtml()}</div>`;
    return;
  }

  const searchInput = document.getElementById("search-input");
  const query = searchInput ? searchInput.value : "";

  grid.innerHTML = "";
  mediaData.forEach((row, index) => {
    const card = document.createElement("div");
    card.className = "grid-card";
    card.tabIndex = 0;
    card.setAttribute("role", "button");
    card.dataset.rowIndex = String(index);

    const fileBase = row.path.split("/").pop();
    const dirPath = row.path.substring(0, row.path.lastIndexOf("/"));

    card.setAttribute("aria-label", `View details for ${fileBase}`);

    const isVideo =
      VIDEO_FORMATS.includes((row.format || "").toLowerCase()) ||
      row.duration_sec !== null;

    let thumbHtml = "";
    if (row.has_thumbnail) {
      const url = `/api/thumbnail?path=${encodeURIComponent(row.path)}`;
      const animatedOverlay = row.has_animated
        ? `<img src="/api/thumbnail?path=${encodeURIComponent(row.path)}&animated=1" class="animated-overlay" alt="" loading="lazy" aria-hidden="true" />`
        : "";
      thumbHtml = `${animatedOverlay}<img src="${escapeHtml(url)}" alt="${escapeHtml(fileBase)}" loading="lazy" />`;
    } else if (isVideo) {
      thumbHtml = `<i data-lucide="video" class="type-icon video-icon"></i>`;
    } else {
      thumbHtml = `<i data-lucide="image" class="type-icon image-icon"></i>`;
    }

    const mediaClass = row.has_animated
      ? "grid-card-media has-animated"
      : "grid-card-media";

    // Format badge
    const formatBadge = row.format
      ? `<span class="grid-card-badge">${highlightMatch((row.format || "").toUpperCase(), query)}</span>`
      : "";

    // Permanent Video Badge with duration overlay if available
    let videoBadge = "";
    if (isVideo) {
      let durText = "";
      if (row.duration_sec != null) {
        const secs = Math.round(row.duration_sec);
        const h = Math.floor(secs / 3600);
        const m = Math.floor((secs % 3600) / 60);
        const s = secs % 60;
        if (h > 0) {
          durText = `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
        } else {
          durText = `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
        }
      }
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
