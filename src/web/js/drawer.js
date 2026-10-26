// Details Drawer State
let drawerIndex = -1;

// Helper: Copy text to clipboard and show visual checkmark feedback
async function copyToClipboard(text, btnElement) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
    } else {
      // Fallback for non-secure HTTP contexts (e.g. accessing Synology local IP)
      const textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.style.position = "fixed"; // Keep offscreen/avoid layout shifts
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      const successful = document.execCommand("copy");
      document.body.removeChild(textarea);
      if (!successful) throw new Error("Fallback copy command failed");
    }
    btnElement.classList.add("copied");
    if (btnElement._copyTimeout) {
      clearTimeout(btnElement._copyTimeout);
    }
    btnElement._copyTimeout = setTimeout(() => {
      btnElement.classList.remove("copied");
      btnElement._copyTimeout = null;
    }, 1500);
    showToast("Copied to clipboard", "success");
  } catch (err) {
    console.error("Failed to copy text:", err);
    showToast("Failed to copy to clipboard", "error");
  }
}

// Helper: Handler for copy buttons in drawer
function copyValue(btnElement) {
  const valSpan = btnElement.previousElementSibling;
  if (valSpan) {
    copyToClipboard(valSpan.textContent.trim(), btnElement);
    // Clear any selection range that might be triggered by browser behavior
    if (window.getSelection) {
      window.getSelection().removeAllRanges();
    }
  }
}

// Update previous / next buttons and position counter in drawer header
function updateDrawerNavigation() {
  const prevBtn = document.getElementById("drawer-prev-btn");
  const nextBtn = document.getElementById("drawer-next-btn");
  const counter = document.getElementById("drawer-counter");

  if (counter) {
    if (drawerIndex >= 0 && mediaData.length > 0) {
      counter.textContent = `${drawerIndex + 1} of ${mediaData.length}`;
    } else {
      counter.textContent = "";
    }
  }

  if (prevBtn) {
    prevBtn.disabled = drawerIndex <= 0;
  }
  if (nextBtn) {
    nextBtn.disabled = drawerIndex < 0 || drawerIndex >= mediaData.length - 1;
  }
}

// Open Quick Look Lightbox directly from the details drawer preview
function openLightboxFromDrawer() {
  if (drawerIndex >= 0 && drawerIndex < mediaData.length) {
    openLightbox(drawerIndex);
  }
}

// Keyboard trigger for preview container
function handleDrawerPreviewKeydown(e) {
  if (e.key === "Enter" || e.key === " ") {
    e.preventDefault();
    openLightboxFromDrawer();
  }
}

// Navigate to previous or next media item in details drawer
function navigateDrawer(step) {
  if (mediaData.length === 0) return;
  const nextIdx = drawerIndex + step;
  if (nextIdx < 0 || nextIdx >= mediaData.length) return;

  handleNotesDrawerClose();

  drawerIndex = nextIdx;
  setSelectedIndex(drawerIndex, { scrollToView: true });

  const activeEl =
    document.querySelector(
      `#media-tbody tr[data-row-index="${drawerIndex}"]`,
    ) ||
    document.querySelector(
      `#media-grid .grid-card[data-row-index="${drawerIndex}"]`,
    );
  drawerReturnFocus = activeEl || drawerReturnFocus;

  renderDrawerBody(mediaData[drawerIndex]);

  const drawer = document.getElementById("details-drawer");
  drawer?.focus({ preventScroll: true });
}

// Render dynamic metadata sections inside the drawer
function renderDrawerBody(row) {
  const drawer = document.getElementById("details-drawer");
  const content = document.getElementById("drawer-content");
  if (!drawer || !content || !row) return;

  // Pause any playing video in the drawer before re-rendering
  const video = drawer.querySelector("video");
  if (video) {
    video.pause();
    video.removeAttribute("src");
    video.load();
  }

  const fileBase = row.path.split("/").pop();
  const isVid = isVideo(row);

  let html = "";
  if (isVid) {
    const posterAttr = row.has_thumbnail
      ? ` poster="/api/thumbnail?path=${encodeURIComponent(row.path)}"`
      : "";
    html += `
          <div class="drawer-preview-container">
              <video class="drawer-preview-video" controls preload="metadata"${posterAttr} src="/api/file?path=${encodeURIComponent(row.path)}">
                  Your browser does not support the video tag.
              </video>
          </div>
    `;
  } else if (row.has_thumbnail) {
    const containerClass = row.has_animated
      ? "drawer-preview-container drawer-preview-interactive has-animated"
      : "drawer-preview-container drawer-preview-interactive";
    html += `
          <div class="${escapeHtml(containerClass)}" role="button" tabindex="0" onclick="openLightboxFromDrawer()" onkeydown="handleDrawerPreviewKeydown(event)" title="Click to view fullscreen (Space)" aria-label="View fullscreen preview">
              ${renderThumbnailHtml(row, "drawer-preview-image", "Thumbnail Preview")}
          </div>
    `;
  }

  html += `
          <div class="detail-section">
              <h3>File Info</h3>
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

  html += renderNotesSection(row);

  if (row.width && row.height) {
    html += `
              <div class="detail-section">
                  <h3>Dimensions</h3>
                  <div class="detail-row"><span class="label">Width:</span><span class="value">${escapeHtml(String(row.width))} px</span></div>
                  <div class="detail-row"><span class="label">Height:</span><span class="value">${escapeHtml(String(row.height))} px</span></div>
                  <div class="detail-row"><span class="label">Aspect Ratio:</span><span class="value">${escapeHtml(calculateAspectRatio(row.width, row.height))}</span></div>
                  ${row.orientation ? `<div class="detail-row"><span class="label">Orientation:</span><span class="value">${escapeHtml(ORIENTATION_LABELS[row.orientation] ?? `EXIF ${row.orientation}`)}</span></div>` : ""}
              </div>
          `;
  }

  if (isVid && row.duration_sec) {
    html += `
              <div class="detail-section">
                  <h3>Video Properties</h3>
                  <div class="detail-row"><span class="label">Duration:</span><span class="value">${escapeHtml(formatDuration(row.duration_sec))}</span></div>
              </div>
          `;
  }

  if (row.create_time || row.camera_make || row.camera_model) {
    html += `
              <div class="detail-section">
                  <h3>Camera & Capture</h3>
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
                  <h3>GPS Location</h3>
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
  bindNotesEvents(row, content);
  updateDrawerNavigation();

  if (
    typeof lucide !== "undefined" &&
    typeof lucide.createIcons === "function"
  ) {
    lucide.createIcons({ root: drawer });
  }
}

// Close the details drawer and its backdrop
function closeDrawer() {
  handleNotesDrawerClose();

  const drawer = document.getElementById("details-drawer");
  drawer.classList.remove("open");
  drawer.setAttribute("inert", "");
  drawer.setAttribute("aria-hidden", "true");
  document.getElementById("drawer-backdrop").classList.remove("visible");
  document.removeEventListener("keydown", handleDrawerKeydown);

  // Pause any playing video in the drawer
  const video = drawer.querySelector("video");
  if (video) {
    video.pause();
    video.removeAttribute("src"); // Stop buffering
    video.load();
  }

  drawerIndex = -1;
  const returnFocus = drawerReturnFocus;
  drawerReturnFocus = null;
  if (returnFocus && typeof returnFocus.focus === "function") {
    returnFocus.focus();
  }
}

// Show metadata details side drawer
function showDetails(row, triggerEl) {
  handleNotesDrawerClose();

  const drawer = document.getElementById("details-drawer");
  drawerReturnFocus = triggerEl || document.activeElement;

  let idx = mediaData.indexOf(row);
  if (idx === -1 && selectedIndex >= 0 && mediaData[selectedIndex] === row) {
    idx = selectedIndex;
  }
  drawerIndex = idx;

  renderDrawerBody(row);

  drawer.classList.add("open");
  drawer.removeAttribute("inert");
  drawer.setAttribute("aria-hidden", "false");
  document.getElementById("drawer-backdrop").classList.add("visible");

  document.removeEventListener("keydown", handleDrawerKeydown);
  document.addEventListener("keydown", handleDrawerKeydown);

  requestAnimationFrame(() => {
    drawer.focus({ preventScroll: true });
  });
}

// Handle keyboard interactions (focus trapping & item navigation) within the open drawer
function handleDrawerKeydown(e) {
  const drawer = document.getElementById("details-drawer");
  if (!drawer || !drawer.classList.contains("open")) return;

  if (e.key === "Escape") {
    e.preventDefault();
    closeDrawer();
    return;
  }

  const isEditingText =
    e.target.tagName === "TEXTAREA" ||
    (e.target.tagName === "INPUT" &&
      (e.target.type === "text" || !e.target.type)) ||
    e.target.isContentEditable;

  if (!isEditingText) {
    if (
      e.key === "[" ||
      e.key === "ArrowLeft" ||
      e.key === "<" ||
      e.key === "," ||
      e.key === "h"
    ) {
      e.preventDefault();
      navigateDrawer(-1);
      return;
    }
    if (
      e.key === "]" ||
      e.key === "ArrowRight" ||
      e.key === ">" ||
      e.key === "." ||
      e.key === "l"
    ) {
      e.preventDefault();
      navigateDrawer(1);
      return;
    }
  }

  trapFocus(e, drawer);
}
