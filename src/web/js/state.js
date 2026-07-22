// Data State
let mediaData = []; // Array containing the current page of media records
let totalRecords = 0; // Total number of records matching the current filters
let statsData = null; // Aggregate statistics data for the catalog
let initialFetchComplete = false; // Flag to prevent UI from rendering empty state during hydration

// Pagination & Sorting State
let currentPage = 1; // The current active page number (1-indexed)
let pageSize = 25; // Number of records displayed per page
let sortConfig = { key: "create_time", direction: "desc" }; // Current sorting configuration

// UI & Modal State
let activeModalTab = "images"; // Tracks which tab is active in the insights modal ('images' or 'videos')
let drawerReturnFocus = null; // Stores the DOM element to return focus to when the details drawer closes
let modalReturnFocus = null; // Stores the DOM element to return focus to when the insights modal closes
let modalSessionId = 0; // Unique ID to ensure charts only render for the latest modal session

// Filter State
let activeDatePreset = null; // Currently active date filter preset (e.g., 'last7')
let activeSizePresetMb = null; // Currently active size filter preset in MB
const FILTER_DEBOUNCE_MS = 500; // Delay in ms before applying search/filter inputs

// Network State
let currentFetchController = null; // AbortController to cancel in-flight API requests when new ones are triggered

// Chart.js Instances (Images)
let imgFormatChart = null;
let imgSizeChart = null;
let imgCameraChart = null;

// Chart.js Instances (Videos)
let vidFormatChart = null;
let vidSizeChart = null;
let vidDurationChart = null;

// Asset Loading
let chartJsLoadPromise = null; // Promise tracking the dynamic loading of Chart.js library

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
