// Encapsulated Notes Module for Media Details Drawer
let activeNotesRecord = null;
let initialNotesValue = "";
let activeNotesSaveController = null;
let notesStatusTimeout = null;

// Render Notes section HTML for details drawer
function renderNotesSection(row) {
  if (!row || !row.file_hash) {
    return `
      <div class="detail-section notes-section">
          <h4>Notes</h4>
          <textarea class="notes-textarea" disabled placeholder="Notes unavailable (missing file hash)..."></textarea>
          <div class="notes-footer">
              <span class="notes-hint disabled-hint">Notes unavailable for this item</span>
          </div>
      </div>
    `;
  }

  const currentNotes = row.notes ?? "";
  const charLength = [...currentNotes].length;

  return `
    <div class="detail-section notes-section">
        <div class="notes-header">
            <h4>Notes</h4>
            <span id="notes-status" class="notes-status" aria-live="polite"></span>
        </div>
        <textarea id="notes-textarea" class="notes-textarea" placeholder="Add personal notes..." maxlength="10000" aria-label="Personal notes">${escapeHtml(currentNotes)}</textarea>
        <div class="notes-footer">
            <span class="notes-hint">Saved on blur or closing drawer</span>
            <span id="notes-char-count" class="notes-char-count">${charLength} / 10,000</span>
        </div>
    </div>
  `;
}

// Bind event listeners for notes textarea in drawer
function bindNotesEvents(row, container) {
  activeNotesRecord = row;
  if (!row || !row.file_hash) {
    initialNotesValue = "";
    return;
  }

  const textarea = container
    ? container.querySelector("#notes-textarea")
    : document.getElementById("notes-textarea");
  if (!textarea) return;

  initialNotesValue = textarea.value.trim();

  // Save on blur
  textarea.addEventListener("blur", () => {
    saveNotesIfDirty();
  });

  // Update character count on input (no save timer)
  textarea.addEventListener("input", () => {
    updateNotesCharCount([...textarea.value].length);
  });
}

// Update character count display
function updateNotesCharCount(count) {
  const charEl = document.getElementById("notes-char-count");
  if (charEl) {
    charEl.textContent = `${count} / 10,000`;
  }
}

// Update status message in notes section header
function showNotesStatus(msg, type) {
  const statusEl = document.getElementById("notes-status");
  if (!statusEl) return;

  if (notesStatusTimeout) {
    clearTimeout(notesStatusTimeout);
    notesStatusTimeout = null;
  }

  statusEl.textContent = msg;
  statusEl.className = "notes-status" + (type ? ` ${type}` : "");

  if (type === "success") {
    notesStatusTimeout = setTimeout(() => {
      if (statusEl.textContent === msg) {
        statusEl.textContent = "";
        statusEl.className = "notes-status";
      }
    }, 2500);
  }
}

// Save notes if modified (dirty-tracking & last-write-wins)
function saveNotesIfDirty() {
  if (!activeNotesRecord || !activeNotesRecord.file_hash) return;

  const textarea = document.getElementById("notes-textarea");
  const currentValue = textarea ? textarea.value.trim() : null;
  if (currentValue === null) return;

  if (currentValue === initialNotesValue) return;

  const targetRecord = activeNotesRecord;
  const targetHash = targetRecord.file_hash;
  const notesToSave = currentValue;

  // Cancel any active save request (last-write-wins)
  if (activeNotesSaveController) {
    activeNotesSaveController.abort();
    activeNotesSaveController = null;
  }

  const controller = new AbortController();
  activeNotesSaveController = controller;

  if (activeNotesRecord === targetRecord) {
    showNotesStatus("Saving...", "saving");
  }

  fetch("/api/notes", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      hash: targetHash,
      notes: notesToSave,
    }),
    signal: controller.signal,
  })
    .then((res) => {
      if (!res.ok) {
        throw new Error(`Server returned status ${res.status}`);
      }
      return res.json();
    })
    .then(() => {
      // Mutate in-memory record in place on success
      targetRecord.notes = notesToSave;

      if (activeNotesRecord === targetRecord) {
        initialNotesValue = notesToSave;
        showNotesStatus("Saved", "success");
      }
    })
    .catch((err) => {
      if (err.name === "AbortError") return;
      console.error("Failed to save notes:", err);
      if (activeNotesRecord === targetRecord) {
        showNotesStatus("Save failed", "error");
      }
    })
    .finally(() => {
      if (activeNotesSaveController === controller) {
        activeNotesSaveController = null;
      }
    });
}

// Flush pending dirty save and clear active record state on drawer close or row switch
function handleNotesDrawerClose() {
  saveNotesIfDirty();
  activeNotesRecord = null;
  initialNotesValue = "";
}
