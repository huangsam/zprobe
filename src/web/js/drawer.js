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
    setTimeout(() => {
      btnElement.classList.remove("copied");
    }, 1500);
  } catch (err) {
    console.error("Failed to copy text:", err);
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

// Close the details drawer and its backdrop
function closeDrawer() {
  const drawer = document.getElementById("details-drawer");
  drawer.classList.remove("open");
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
      ? "drawer-preview-container has-animated"
      : "drawer-preview-container";
    html += `
          <div class="${escapeHtml(containerClass)}">
              ${renderThumbnailHtml(row, "drawer-preview-image", "Thumbnail Preview")}
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

  if (isVid && row.duration_sec) {
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

function handleDrawerKeydown(e) {
  const drawer = document.getElementById("details-drawer");
  if (!drawer.classList.contains("open")) return;
  trapFocus(e, drawer);
}
