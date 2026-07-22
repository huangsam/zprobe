let mediaData = [];
let totalRecords = 0;
let currentPage = 1;
let pageSize = 25;
let sortConfig = { key: "create_time", direction: "desc" };
let activeModalTab = "images";
let currentFetchController = null;
let statsData = null;
let activeDatePreset = null;
let activeSizePresetMb = null;
let drawerReturnFocus = null;
let modalReturnFocus = null;
let modalSessionId = 0;
let initialFetchComplete = false;

const FILTER_DEBOUNCE_MS = 500;

let imgFormatChart = null;
let imgSizeChart = null;
let imgCameraChart = null;

let vidFormatChart = null;
let vidSizeChart = null;
let vidDurationChart = null;

let chartJsLoadPromise = null;

// ORIENTATION_LABELS maps EXIF orientation values to human readable descriptions.
const ORIENTATION_LABELS = {
  1: "Horizontal (normal)",
  2: "Mirror horizontal",
  3: "Rotated 180\u00b0",
  4: "Mirror vertical",
  5: "Mirror horizontal and rotated 270\u00b0 CW",
  6: "Rotated 90\u00b0 CW",
  8: "Rotated 270\u00b0 CW",
};

// VIDEO_FORMATS must mirror media_scan.videoExtensions and db/types.zig video_formats_sql.
const VIDEO_FORMATS = ["mp4", "m4v", "webm", "mkv", "mov", "avi", "wmv", "flv"];
