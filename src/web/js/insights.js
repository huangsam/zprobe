// Calculate and display metrics
function populateStats() {
  if (!statsData) return;
  const summary = document.getElementById("stats-live-summary");
  if (summary) {
    summary.textContent = `Catalog: ${formatCount(statsData.total_files)} files, ${formatBytes(statsData.total_size)} total, ${formatCount(statsData.num_images)} images, ${formatCount(statsData.num_videos)} videos`;
  }
}

function loadChartJs() {
  if (window.Chart) return Promise.resolve();
  if (!chartJsLoadPromise) {
    chartJsLoadPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "/js/chart.umd.js";
      script.onload = () => resolve();
      script.onerror = () => reject(new Error("Failed to load Chart.js"));
      document.head.appendChild(script);
    });
  }
  return chartJsLoadPromise;
}

function handleModalBackdropClick(event) {
  const modal = document.getElementById("insights-modal");
  if (event.target === modal) {
    toggleModal(false);
  }
}

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
}

function resizeActiveCharts() {
  if (activeModalTab === "images") {
    imgFormatChart?.resize();
    imgSizeChart?.resize();
    imgCameraChart?.resize();
  } else {
    vidFormatChart?.resize();
    vidSizeChart?.resize();
    vidDurationChart?.resize();
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

function handleModalKeydown(e) {
  const modal = document.getElementById("insights-modal");
  if (!modal.classList.contains("open")) return;
  const dialog = modal.querySelector(".modal-content");
  if (dialog) trapFocus(e, dialog);
}

function handleModalTablistKeydown(e) {
  if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
  const modal = document.getElementById("insights-modal");
  if (!modal.classList.contains("open")) return;
  const tabs = ["images", "videos"];
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
