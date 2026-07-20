// Calculate and display metrics
function populateStats() {
  if (!statsData) return;
  const metricIds = [
    "stat-total-files",
    "stat-total-size",
    "stat-images",
    "stat-videos",
  ];
  metricIds.forEach((id) => {
    const el = document.getElementById(id);
    if (el) {
      el.classList.remove("error-state");
    }
  });
  const filesVal = formatCount(statsData.total_files);
  const sizeVal = formatBytes(statsData.total_size);
  const imagesVal = formatCount(statsData.num_images);
  const videosVal = formatCount(statsData.num_videos);

  const filesEl = document.getElementById("stat-total-files");
  if (filesEl) {
    filesEl.textContent = filesVal;
    filesEl.title = filesVal;
  }
  const sizeEl = document.getElementById("stat-total-size");
  if (sizeEl) {
    sizeEl.textContent = sizeVal;
    sizeEl.title = sizeVal;
  }
  const imagesEl = document.getElementById("stat-images");
  if (imagesEl) {
    imagesEl.textContent = imagesVal;
    imagesEl.title = imagesVal;
  }
  const videosEl = document.getElementById("stat-videos");
  if (videosEl) {
    videosEl.textContent = videosVal;
    videosEl.title = videosVal;
  }

  const summary = document.getElementById("stats-live-summary");
  if (summary) {
    summary.textContent = `Catalog: ${formatCount(statsData.total_files)} files, ${formatBytes(statsData.total_size)} total, ${formatCount(statsData.num_images)} images, ${formatCount(statsData.num_videos)} videos`;
  }
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
      row.width && row.height
        ? `${escapeHtml(String(row.width))} &times; ${escapeHtml(String(row.height))}`
        : "—";
    const fileBase = row.path.split("/").pop();
    const dirPath = row.path.substring(0, row.path.lastIndexOf("/"));

    tr.setAttribute("aria-label", `View details for ${fileBase}`);

    const isVideo =
      VIDEO_FORMATS.includes((row.format || "").toLowerCase()) ||
      row.duration_sec !== null;
    let thumbHtml = "";
    if (row.has_thumbnail) {
      const url = `/api/thumbnail?path=${encodeURIComponent(row.path)}`;
      // If the row has an animated GIF preview, render it as an overlay that
      // fades in on hover (CSS .has-animated:hover .animated-overlay).
      const animatedOverlay = row.has_animated
        ? `<img src="/api/thumbnail?path=${encodeURIComponent(row.path)}&animated=1" class="row-thumbnail animated-overlay" alt="" loading="lazy" aria-hidden="true" />`
        : "";
      thumbHtml = `${animatedOverlay}<img src="${escapeHtml(url)}" class="row-thumbnail" alt="Thumbnail" loading="lazy" />`;
    } else if (isVideo) {
      thumbHtml = `<i data-lucide="video" class="type-icon video-icon"></i>`;
    } else {
      thumbHtml = `<i data-lucide="image" class="type-icon image-icon"></i>`;
    }
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
  const isVideo =
    VIDEO_FORMATS.includes((row.format || "").toLowerCase()) ||
    row.duration_sec !== null;

  let html = "";
  if (row.has_thumbnail) {
    const url = `/api/thumbnail?path=${encodeURIComponent(row.path)}`;
    const animatedOverlay = row.has_animated
      ? `<img src="/api/thumbnail?path=${encodeURIComponent(row.path)}&animated=1" class="drawer-preview-image animated-overlay" alt="" loading="lazy" aria-hidden="true" />`
      : "";
    const containerClass = row.has_animated
      ? "drawer-preview-container has-animated"
      : "drawer-preview-container";
    html += `
          <div class="${escapeHtml(containerClass)}">
              ${animatedOverlay}
              <img src="${escapeHtml(url)}" class="drawer-preview-image" alt="Thumbnail Preview" />
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
              <div class="detail-row"><span class="label">Size:</span><span class="value">${escapeHtml(formatBytes(row.size))} (${escapeHtml(String(row.size))} bytes)</span></div>
              <div class="detail-row"><span class="label">Format:</span><span class="value">${escapeHtml((row.format || "").toUpperCase())}</span></div>
              <div class="detail-row">
                  <span class="label">Download:</span>
                  <span class="value">
                      <a href="/api/file?path=${encodeURIComponent(row.path)}" download="${escapeHtml(fileBase)}" target="_blank" class="map-link">
                          Download Original <i data-lucide="download" class="inline-icon" aria-hidden="true"></i>
                      </a>
                  </span>
              </div>
          </div>
      `;

  if (row.width && row.height) {
    html += `
              <div class="detail-section">
                  <h4>Dimensions</h4>
                  <div class="detail-row"><span class="label">Width:</span><span class="value">${escapeHtml(String(row.width))} px</span></div>
                  <div class="detail-row"><span class="label">Height:</span><span class="value">${escapeHtml(String(row.height))} px</span></div>
                  <div class="detail-row"><span class="label">Aspect Ratio:</span><span class="value">${escapeHtml(calculateAspectRatio(row.width, row.height))}</span></div>
                  ${row.orientation ? `<div class="detail-row"><span class="label">Orientation:</span><span class="value">${escapeHtml(ORIENTATION_LABELS[row.orientation] ?? `EXIF ${row.orientation}`)}</span></div>` : ""}
              </div>
          `;
  }

  if (isVideo && row.duration_sec) {
    html += `
              <div class="detail-section">
                  <h4>Video Properties</h4>
                  <div class="detail-row"><span class="label">Duration:</span><span class="value">${escapeHtml(formatDuration(row.duration_sec))}</span></div>
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
                          <span class="value">${escapeHtml(gpsCoords)}</span>
                          <button class="copy-btn" onclick="copyValue(this)" aria-label="Copy coordinates">
                              <i data-lucide="copy" aria-hidden="true"></i>
                          </button>
                      </span>
                  </div>
                  <div class="detail-row">
                      <span class="label">Map Link:</span>
                      <span class="value">
                          <a href="${escapeHtml(mapsUrl)}" target="_blank" class="map-link">
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
  if (
    typeof lucide !== "undefined" &&
    typeof lucide.createIcons === "function"
  ) {
    lucide.createIcons({ root: drawer });
  }
  document.addEventListener("keydown", handleDrawerKeydown);
  requestAnimationFrame(() => {
    document.getElementById("close-drawer-btn")?.focus();
  });
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

// Render Image-Specific Statistics
function renderImageCharts() {
  if (!statsData) {
    toggleChartPlaceholder(
      "wrapper-img-formats",
      false,
      "Failed to load catalog statistics",
    );
    toggleChartPlaceholder(
      "wrapper-img-sizes",
      false,
      "Failed to load catalog statistics",
    );
    toggleChartPlaceholder(
      "wrapper-img-cameras",
      false,
      "Failed to load catalog statistics",
    );
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
    return;
  }
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
          plugins: {
            legend: { position: window.innerWidth < 640 ? "bottom" : "right" },
          },
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
          plugins: {
            legend: { display: false },
            tooltip: {
              callbacks: {
                title: (items) => items[0]?.label || "",
              },
            },
          },
          scales: {
            x: { beginAtZero: true, ticks: { precision: 0 } },
            y: {
              ticks: {
                callback: function (val) {
                  const label = this.getLabelForValue(val);
                  return label.length > 15 ? label.slice(0, 12) + "..." : label;
                },
              },
            },
          },
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
  if (!statsData) {
    toggleChartPlaceholder(
      "wrapper-vid-formats",
      false,
      "Failed to load catalog statistics",
    );
    toggleChartPlaceholder(
      "wrapper-vid-sizes",
      false,
      "Failed to load catalog statistics",
    );
    toggleChartPlaceholder(
      "wrapper-vid-durations",
      false,
      "Failed to load catalog statistics",
    );
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
    return;
  }
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
          plugins: {
            legend: { position: window.innerWidth < 640 ? "bottom" : "right" },
          },
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
