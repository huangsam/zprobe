// Lightbox / Quick Look Modal State
let lightboxIndex = -1;
let lightboxReturnFocus = null;
let isLightboxZoomed = false;

// Handle keyboard events inside the open lightbox
function handleLightboxKeydown(e) {
  const modal = document.getElementById("lightbox-modal");
  if (!modal || !modal.classList.contains("open")) return;

  if (e.key === "Escape" || e.key === " ") {
    e.preventDefault();
    closeLightbox();
    return;
  }

  if (e.key === "ArrowLeft" || e.key === "h") {
    e.preventDefault();
    navigateLightbox(-1);
    return;
  }

  if (e.key === "ArrowRight" || e.key === "l") {
    e.preventDefault();
    navigateLightbox(1);
    return;
  }

  if (e.key.toLowerCase() === "z") {
    e.preventDefault();
    toggleLightboxZoom();
    return;
  }

  trapFocus(e, modal);
}

// Handle backdrop clicks to dismiss lightbox
function handleLightboxBackdropClick(e) {
  const viewport = document.getElementById("lightbox-viewport");
  if (e.target === viewport || e.target.id === "lightbox-modal") {
    closeLightbox();
  }
}

// Open Quick Look / Lightbox for a specific media index
function openLightbox(index) {
  if (mediaData.length === 0) return;

  let targetIdx = index;
  if (targetIdx == null || targetIdx < 0 || targetIdx >= mediaData.length) {
    targetIdx = selectedIndex >= 0 ? selectedIndex : 0;
  }

  lightboxIndex = targetIdx;
  isLightboxZoomed = false;
  setSelectedIndex(lightboxIndex, { scrollToView: true });

  const modal = document.getElementById("lightbox-modal");
  if (!modal) return;

  lightboxReturnFocus = document.activeElement;
  modal.classList.add("open");
  modal.removeAttribute("inert");
  modal.setAttribute("aria-hidden", "false");

  document.removeEventListener("keydown", handleLightboxKeydown);
  window.removeEventListener("click", handleLightboxBackdropClick);

  document.addEventListener("keydown", handleLightboxKeydown);
  window.addEventListener("click", handleLightboxBackdropClick);

  renderLightboxMedia();

  requestAnimationFrame(() => {
    document.getElementById("close-lightbox-btn")?.focus();
  });
}

// Close Quick Look / Lightbox
function closeLightbox() {
  const modal = document.getElementById("lightbox-modal");
  if (!modal || !modal.classList.contains("open")) return;

  // Clean up video playback
  const video = modal.querySelector("video");
  if (video) {
    video.pause();
    video.removeAttribute("src");
    video.load();
  }

  modal.classList.remove("open");
  modal.setAttribute("inert", "");
  modal.setAttribute("aria-hidden", "true");

  document.removeEventListener("keydown", handleLightboxKeydown);
  window.removeEventListener("click", handleLightboxBackdropClick);

  isLightboxZoomed = false;
  const wrapper = document.getElementById("lightbox-media-wrapper");
  wrapper?.classList.remove("is-zoomed");

  const returnFocus = lightboxReturnFocus;
  lightboxReturnFocus = null;
  if (returnFocus && typeof returnFocus.focus === "function") {
    returnFocus.focus();
  }
}

// Navigate to previous or next item in lightbox
function navigateLightbox(step) {
  if (mediaData.length === 0) return;

  const nextIdx = lightboxIndex + step;
  if (nextIdx < 0 || nextIdx >= mediaData.length) return;

  lightboxIndex = nextIdx;
  isLightboxZoomed = false;
  setSelectedIndex(lightboxIndex, { scrollToView: true });
  renderLightboxMedia();
}

// Toggle 1:1 original zoom vs fit-to-screen
function toggleLightboxZoom() {
  const wrapper = document.getElementById("lightbox-media-wrapper");
  const zoomBtn = document.getElementById("lightbox-zoom-btn");
  if (!wrapper || !zoomBtn) return;

  isLightboxZoomed = !isLightboxZoomed;
  wrapper.classList.toggle("is-zoomed", isLightboxZoomed);

  zoomBtn.innerHTML = isLightboxZoomed
    ? `<i data-lucide="zoom-out" aria-hidden="true"></i>`
    : `<i data-lucide="zoom-in" aria-hidden="true"></i>`;

  zoomBtn.title = isLightboxZoomed
    ? "Fit to screen (Z)"
    : "Toggle 1:1 Zoom (Z)";

  if (
    typeof lucide !== "undefined" &&
    typeof lucide.createIcons === "function"
  ) {
    lucide.createIcons({ root: zoomBtn });
  }
}

// Render active media and metadata into lightbox
function renderLightboxMedia() {
  if (lightboxIndex < 0 || lightboxIndex >= mediaData.length) return;
  const row = mediaData[lightboxIndex];
  if (!row) return;

  const titleEl = document.getElementById("lightbox-title");
  const counterEl = document.getElementById("lightbox-counter");
  const formatBadge = document.getElementById("lightbox-badge-format");
  const dimsBadge = document.getElementById("lightbox-badge-dims");
  const sizeBadge = document.getElementById("lightbox-badge-size");
  const downloadLink = document.getElementById("lightbox-download-link");
  const prevBtn = document.getElementById("lightbox-prev-btn");
  const nextBtn = document.getElementById("lightbox-next-btn");
  const zoomBtn = document.getElementById("lightbox-zoom-btn");
  const wrapper = document.getElementById("lightbox-media-wrapper");

  const fileBase = row.path.split("/").pop();
  const isVid = isVideo(row);

  if (titleEl) titleEl.textContent = fileBase;
  if (counterEl) {
    counterEl.textContent = `${lightboxIndex + 1} of ${mediaData.length}`;
  }
  if (formatBadge) {
    formatBadge.textContent = (row.format || "").toUpperCase();
  }
  if (dimsBadge) {
    dimsBadge.textContent =
      row.width && row.height ? `${row.width} \u00d7 ${row.height}` : "—";
  }
  if (sizeBadge) {
    sizeBadge.textContent = formatBytes(row.size);
  }

  if (downloadLink) {
    downloadLink.href = `/api/file?path=${encodeURIComponent(row.path)}`;
    downloadLink.setAttribute("download", fileBase);
  }

  if (prevBtn) prevBtn.disabled = lightboxIndex <= 0;
  if (nextBtn) nextBtn.disabled = lightboxIndex >= mediaData.length - 1;

  wrapper?.classList.remove("is-zoomed");
  isLightboxZoomed = false;

  if (isVid) {
    if (zoomBtn) zoomBtn.hidden = true;
    const posterAttr = row.has_thumbnail
      ? ` poster="/api/thumbnail?path=${encodeURIComponent(row.path)}"`
      : "";
    wrapper.innerHTML = `
      <video class="lightbox-video" controls autoplay preload="auto"${posterAttr} src="/api/file?path=${encodeURIComponent(row.path)}">
        Your browser does not support HTML5 video.
      </video>
    `;
  } else {
    if (zoomBtn) {
      zoomBtn.hidden = false;
      zoomBtn.innerHTML = `<i data-lucide="zoom-in" aria-hidden="true"></i>`;
      zoomBtn.title = "Toggle 1:1 Zoom (Z)";
      if (
        typeof lucide !== "undefined" &&
        typeof lucide.createIcons === "function"
      ) {
        lucide.createIcons({ root: zoomBtn });
      }
    }
    wrapper.innerHTML = `
      <img
        class="lightbox-image"
        src="/api/file?path=${encodeURIComponent(row.path)}"
        alt="${escapeHtml(fileBase)}"
        loading="eager"
        decoding="async"
      />
    `;

    const img = wrapper.querySelector(".lightbox-image");
    img?.addEventListener("dblclick", toggleLightboxZoom);
  }

  const modal = document.getElementById("lightbox-modal");
  if (
    modal &&
    typeof lucide !== "undefined" &&
    typeof lucide.createIcons === "function"
  ) {
    lucide.createIcons({ root: modal });
  }
}
