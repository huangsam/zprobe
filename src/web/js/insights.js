// Calculate and display metrics
function populateStats() {
  if (!statsData) return;
  const summary = document.getElementById("stats-live-summary");
  if (summary) {
    summary.textContent = `Catalog: ${formatCount(statsData.total_files)} files, ${formatBytes(statsData.total_size)} total, ${formatCount(statsData.num_images)} images, ${formatCount(statsData.num_videos)} videos`;
  }
  const imgCount = document.getElementById("stat-img-count");
  if (imgCount) imgCount.textContent = formatCount(statsData.num_images || 0);

  const imgSize = document.getElementById("stat-img-size");
  if (imgSize)
    imgSize.textContent = formatBytes(statsData.image_total_size || 0);

  const imgDupeCount = document.getElementById("stat-img-dupe-count");
  if (imgDupeCount)
    imgDupeCount.textContent = formatCount(statsData.image_dupe_count || 0);

  const imgDupeSize = document.getElementById("stat-img-dupe-size");
  if (imgDupeSize)
    imgDupeSize.textContent = formatBytes(statsData.image_dupe_size || 0);

  const vidCount = document.getElementById("stat-vid-count");
  if (vidCount) vidCount.textContent = formatCount(statsData.num_videos || 0);

  const vidSize = document.getElementById("stat-vid-size");
  if (vidSize)
    vidSize.textContent = formatBytes(statsData.video_total_size || 0);

  const vidDupeCount = document.getElementById("stat-vid-dupe-count");
  if (vidDupeCount)
    vidDupeCount.textContent = formatCount(statsData.video_dupe_count || 0);

  const vidDupeSize = document.getElementById("stat-vid-dupe-size");
  if (vidDupeSize)
    vidDupeSize.textContent = formatBytes(statsData.video_dupe_size || 0);

  const dupeFiles =
    (statsData.image_dupe_count || 0) + (statsData.video_dupe_count || 0);
  const dupeSize =
    (statsData.image_dupe_size || 0) + (statsData.video_dupe_size || 0);
  const dupeFilesEl = document.getElementById("stat-dupe-files");
  if (dupeFilesEl) dupeFilesEl.textContent = formatCount(dupeFiles);
  const dupeWastedEl = document.getElementById("stat-dupe-wasted");
  if (dupeWastedEl) dupeWastedEl.textContent = formatBytes(dupeSize);
}

// Dynamically load the Chart.js library if it hasn't been loaded yet
function loadChartJs() {
  if (window.Chart) {
    applyChartThemeDefaults();
    return Promise.resolve();
  }
  if (!chartJsLoadPromise) {
    chartJsLoadPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "/js/chart.umd.js";
      script.onload = () => {
        applyChartThemeDefaults();
        resolve();
      };
      script.onerror = () => reject(new Error("Failed to load Chart.js"));
      document.head.appendChild(script);
    });
  }
  return chartJsLoadPromise;
}

// Sync Chart.js global defaults with active light/dark theme tokens
function getChartThemePalette() {
  const isDark =
    typeof getResolvedTheme === "function" && getResolvedTheme() === "dark";
  return {
    textColor: isDark ? "#9fb0c3" : "#666666",
    gridColor: isDark ? "rgba(255, 255, 255, 0.08)" : "rgba(0, 0, 0, 0.06)",
    surfaceBorder: isDark ? "#18202c" : "#ffffff",
  };
}

function applyChartThemeDefaults() {
  if (!window.Chart) return;
  const palette = getChartThemePalette();
  window.Chart.defaults.color = palette.textColor;
  window.Chart.defaults.borderColor = palette.gridColor;
}

function refreshChartsTheme() {
  if (!window.Chart) return;
  applyChartThemeDefaults();
  const modal = document.getElementById("insights-modal");
  if (modal && modal.classList.contains("open")) {
    destroyAllCharts();
    switchModalTab(activeModalTab);
  }
}

// Handle clicking outside the modal content to close it
function handleModalBackdropClick(event) {
  const modal = document.getElementById("insights-modal");
  if (event.target === modal) {
    toggleModal(false);
  }
}

// Destroy all active Chart.js instances to free memory
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
  if (imgTimelineChart) {
    imgTimelineChart.destroy();
    imgTimelineChart = null;
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
  if (vidTimelineChart) {
    vidTimelineChart.destroy();
    vidTimelineChart = null;
  }
}

// Trigger a resize on all active charts to ensure they fit their containers
function resizeActiveCharts() {
  if (activeModalTab === "images") {
    imgFormatChart?.resize();
    imgSizeChart?.resize();
    imgCameraChart?.resize();
    imgTimelineChart?.resize();
  } else {
    vidFormatChart?.resize();
    vidSizeChart?.resize();
    vidDurationChart?.resize();
    vidTimelineChart?.resize();
  }
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

// Open or close the insights modal and manage focus trapping
async function toggleModal(show) {
  const modal = document.getElementById("insights-modal");
  if (show) {
    if (modal.classList.contains("open")) return;
    modal.classList.add("open");
    modal.removeAttribute("inert");
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
    modal.setAttribute("inert", "");
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

  const tabs = ["images", "videos", "duplicates"];
  tabs.forEach((t) => {
    const btn = document.getElementById(`tab-btn-${t}`);
    const pane = document.getElementById(`tab-pane-${t}`);
    const isTarget = t === tabName;
    if (btn) {
      btn.classList.toggle("active", isTarget);
      btn.setAttribute("aria-selected", isTarget ? "true" : "false");
      btn.tabIndex = isTarget ? 0 : -1;
    }
    if (pane) {
      pane.classList.toggle("active", isTarget);
      pane.hidden = !isTarget;
    }
  });

  if (tabName === "images") {
    renderImageCharts();
  } else if (tabName === "videos") {
    renderVideoCharts();
  } else if (tabName === "duplicates") {
    loadDuplicatesTab(duplicatesPage);
  }
  resizeActiveCharts();
}

// Load duplicate media sets from backend
async function loadDuplicatesTab(page = 1) {
  duplicatesPage = page;
  const container = document.getElementById("duplicates-list");
  const pagination = document.getElementById("duplicates-pagination");
  if (!container) return;

  container.setAttribute("aria-busy", "true");
  container.innerHTML = `
    <div class="duplicates-loading">
      <div class="spinner"></div>
      <span>Loading duplicate media sets...</span>
    </div>
  `;

  try {
    const offset = (duplicatesPage - 1) * DUPLICATES_PAGE_SIZE;
    const res = await fetchDuplicates({ limit: DUPLICATES_PAGE_SIZE, offset });
    duplicatesData = res;

    const setsEl = document.getElementById("stat-dupe-sets");
    if (setsEl) setsEl.textContent = formatCount(res.total_duplicate_sets || 0);

    const filesEl = document.getElementById("stat-dupe-files");
    if (filesEl)
      filesEl.textContent = formatCount(res.total_duplicate_files || 0);

    const wastedEl = document.getElementById("stat-dupe-wasted");
    if (wastedEl)
      wastedEl.textContent = formatBytes(res.total_wasted_bytes || 0);

    renderDuplicatesList(res);
  } catch (err) {
    console.error("Failed to load duplicates:", err);
    container.innerHTML = `
      <div class="duplicates-error">
        <i data-lucide="alert-triangle" class="error-icon" aria-hidden="true"></i>
        <span>Failed to load duplicates: ${escapeHtml(err.message)}</span>
        <button type="button" class="btn btn-secondary btn-sm" id="dupe-retry-btn">Retry</button>
      </div>
    `;
    document.getElementById("dupe-retry-btn")?.addEventListener("click", () => {
      loadDuplicatesTab(duplicatesPage);
    });
    if (
      typeof lucide !== "undefined" &&
      typeof lucide.createIcons === "function"
    ) {
      lucide.createIcons({ root: container });
    }
  } finally {
    container.setAttribute("aria-busy", "false");
  }
}

// Render duplicate media sets
function renderDuplicatesList(res) {
  const container = document.getElementById("duplicates-list");
  const pagination = document.getElementById("duplicates-pagination");
  if (!container) return;

  if (!res.sets || res.sets.length === 0) {
    container.innerHTML = `
      <div class="duplicates-empty">
        <div class="empty-icon-wrapper">
          <i data-lucide="check-circle" class="lucide" aria-hidden="true"></i>
        </div>
        <p class="empty-title">No duplicate media found</p>
        <p class="empty-subtitle">All files in this catalog have unique content signatures.</p>
      </div>
    `;
    if (pagination) pagination.hidden = true;
    if (
      typeof lucide !== "undefined" &&
      typeof lucide.createIcons === "function"
    ) {
      lucide.createIcons({ root: container });
    }
    return;
  }

  const itemsHtml = res.sets
    .map((set) => {
      const isVideo = VIDEO_FORMATS.includes(set.format.toLowerCase());
      const thumbUrl = set.has_thumbnail
        ? `/api/thumbnail?hash=${encodeURIComponent(set.file_hash)}`
        : null;
      const countBadge = `${set.count} files`;
      const wastedBadge = `${formatBytes(set.wasted_bytes)} wasted`;
      const dimOrDur = isVideo
        ? set.duration_sec
          ? formatDigitalDuration(set.duration_sec)
          : set.width && set.height
            ? `${set.width}\u00d7${set.height}`
            : ""
        : set.width && set.height
          ? `${set.width}\u00d7${set.height}`
          : "";

      const pathsHtml = set.paths
        .map(
          (p) => `
        <li class="duplicate-path-row">
          <span class="duplicate-path-text" title="${escapeHtml(p)}">${escapeHtml(p)}</span>
          <button type="button" class="btn btn-secondary btn-icon-only copy-path-btn" data-path="${escapeHtml(p)}" title="Copy path" aria-label="Copy file path">
            <i data-lucide="copy" class="btn-icon" aria-hidden="true"></i>
          </button>
        </li>
      `,
        )
        .join("");

      return `
        <article class="duplicate-card">
          <div class="duplicate-card-header">
            <div class="duplicate-thumb">
              ${
                thumbUrl
                  ? `<img src="${thumbUrl}" alt="Duplicate preview" loading="lazy" class="duplicate-thumb-img" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">
                     <div class="duplicate-thumb-placeholder" style="display:none"><i data-lucide="${isVideo ? "video" : "image"}" class="lucide" aria-hidden="true"></i></div>`
                  : `<div class="duplicate-thumb-placeholder"><i data-lucide="${isVideo ? "video" : "image"}" class="lucide" aria-hidden="true"></i></div>`
              }
            </div>
            <div class="duplicate-card-info">
              <div class="duplicate-title-row">
                <span class="duplicate-hash" title="${escapeHtml(set.file_hash)}">${escapeHtml(set.file_hash.substring(0, 16))}...</span>
                <span class="duplicate-badge-wasted">${escapeHtml(wastedBadge)}</span>
              </div>
              <div class="duplicate-meta-row">
                <span class="badge format-badge format-${escapeHtml(set.format.toLowerCase())}">${escapeHtml(set.format.toUpperCase())}</span>
                ${dimOrDur ? `<span class="duplicate-meta-item">${escapeHtml(dimOrDur)}</span>` : ""}
                <span class="duplicate-meta-item">${formatBytes(set.size)} each</span>
                <span class="duplicate-meta-item duplicate-count-item">${countBadge}</span>
              </div>
            </div>
          </div>
          <details class="duplicate-paths-details" open>
            <summary class="duplicate-paths-summary">
              <span>File Locations (${set.paths.length})</span>
            </summary>
            <ul class="duplicate-paths-list">
              ${pathsHtml}
            </ul>
          </details>
        </article>
      `;
    })
    .join("");

  container.innerHTML = itemsHtml;

  // Bind copy path buttons
  container.querySelectorAll(".copy-path-btn").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const p = btn.getAttribute("data-path");
      if (!p) return;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard
          .writeText(p)
          .then(() => {
            showToast("Path copied to clipboard", "success");
          })
          .catch(() => {
            showToast("Failed to copy path", "error");
          });
      } else {
        showToast("Clipboard not available", "error");
      }
    });
  });

  if (
    typeof lucide !== "undefined" &&
    typeof lucide.createIcons === "function"
  ) {
    lucide.createIcons({ root: container });
  }

  // Update pagination controls
  const totalPages =
    Math.ceil(res.total_duplicate_sets / DUPLICATES_PAGE_SIZE) || 1;
  if (pagination) {
    if (totalPages > 1) {
      pagination.hidden = false;
      const prevBtn = document.getElementById("dupe-prev-btn");
      const nextBtn = document.getElementById("dupe-next-btn");
      const pageInfo = document.getElementById("dupe-page-info");

      if (prevBtn) prevBtn.disabled = duplicatesPage <= 1;
      if (nextBtn) nextBtn.disabled = duplicatesPage >= totalPages;
      if (pageInfo)
        pageInfo.textContent = `Page ${duplicatesPage} of ${totalPages}`;
    } else {
      pagination.hidden = true;
    }
  }
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
    toggleChartPlaceholder(
      "wrapper-img-timeline",
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
    if (imgTimelineChart) {
      imgTimelineChart.destroy();
      imgTimelineChart = null;
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
              borderColor: getChartThemePalette().surfaceBorder,
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

  // 4. IMAGE TIMELINE
  const hasImgTimeline =
    hasImages &&
    statsData.image_timeline &&
    statsData.image_timeline.length > 0;
  toggleChartPlaceholder(
    "wrapper-img-timeline",
    hasImgTimeline,
    "No timeline date metadata available for images",
  );

  if (hasImgTimeline) {
    const labels = statsData.image_timeline.map((item) => item.date_key);
    const data = statsData.image_timeline.map((item) => item.count);

    if (imgTimelineChart) {
      imgTimelineChart.data.labels = labels;
      imgTimelineChart.data.datasets[0].data = data;
      imgTimelineChart.update();
    } else {
      const timelineCtx = document
        .getElementById("chart-img-timeline")
        .getContext("2d");
      imgTimelineChart = createTimelineChart(
        timelineCtx,
        labels,
        data,
        "#2b76db",
      );
    }
  } else if (imgTimelineChart) {
    imgTimelineChart.destroy();
    imgTimelineChart = null;
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
    toggleChartPlaceholder(
      "wrapper-vid-timeline",
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
    if (vidTimelineChart) {
      vidTimelineChart.destroy();
      vidTimelineChart = null;
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
              borderColor: getChartThemePalette().surfaceBorder,
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

  // 4. VIDEO TIMELINE
  const hasVidTimeline =
    hasVideos &&
    statsData.video_timeline &&
    statsData.video_timeline.length > 0;
  toggleChartPlaceholder(
    "wrapper-vid-timeline",
    hasVidTimeline,
    "No timeline date metadata available for videos",
  );

  if (hasVidTimeline) {
    const labels = statsData.video_timeline.map((item) => item.date_key);
    const data = statsData.video_timeline.map((item) => item.count);

    if (vidTimelineChart) {
      vidTimelineChart.data.labels = labels;
      vidTimelineChart.data.datasets[0].data = data;
      vidTimelineChart.update();
    } else {
      const timelineCtx = document
        .getElementById("chart-vid-timeline")
        .getContext("2d");
      vidTimelineChart = createTimelineChart(
        timelineCtx,
        labels,
        data,
        "#38bdf8",
      );
    }
  } else if (vidTimelineChart) {
    vidTimelineChart.destroy();
    vidTimelineChart = null;
  }
}

// Helper to create smooth timeline area chart
function createTimelineChart(ctx, labels, data, colorHex) {
  const gradient = ctx.createLinearGradient(0, 0, 0, 200);
  gradient.addColorStop(0, colorHex + "66");
  gradient.addColorStop(1, colorHex + "05");

  return new Chart(ctx, {
    type: "line",
    data: {
      labels: labels,
      datasets: [
        {
          label: "Media Count",
          data: data,
          fill: true,
          backgroundColor: gradient,
          borderColor: colorHex,
          borderWidth: 2,
          tension: 0.3,
          pointRadius: labels.length > 30 ? 2 : 4,
          pointHoverRadius: 6,
          pointBackgroundColor: colorHex,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          mode: "index",
          intersect: false,
          callbacks: {
            label: (context) => ` Files: ${context.parsed.y}`,
          },
        },
      },
      scales: {
        x: {
          grid: { display: false },
          ticks: { maxRotation: 45, autoSkip: true, maxTicksLimit: 12 },
        },
        y: {
          beginAtZero: true,
          ticks: { precision: 0 },
        },
      },
    },
  });
}

// Trap keyboard focus within the modal while it is open
function handleModalKeydown(e) {
  const modal = document.getElementById("insights-modal");
  if (!modal.classList.contains("open")) return;
  const dialog = modal.querySelector(".modal-content");
  if (dialog) trapFocus(e, dialog);
}

// Handle left/right arrow key navigation between modal tabs
function handleModalTablistKeydown(e) {
  if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
  const modal = document.getElementById("insights-modal");
  if (!modal.classList.contains("open")) return;
  const tabs = ["images", "videos", "duplicates"];
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
