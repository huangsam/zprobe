const std = @import("std");

// Static Shell & Media Assets
pub const index_html = @embedFile("index.html");
pub const logo_svg = @embedFile("logo.svg");
pub const lucide_js = @embedFile("js/vendor/lucide.min.js");
pub const chart_js = @embedFile("js/vendor/chart.umd.js");
pub const font_outfit_600 = @embedFile("fonts/outfit-600.woff2");
pub const font_pj_400 = @embedFile("fonts/plus-jakarta-400.woff2");
pub const font_pj_600 = @embedFile("fonts/plus-jakarta-600.woff2");

// CSS components compiled at compile time
const css_var = @embedFile("css/variables.css");
const css_lay = @embedFile("css/layout.css");
const css_tbl = @embedFile("css/table.css");
const css_grd = @embedFile("css/grid.css");
pub const styles_css = css_var ++ css_lay ++ css_tbl ++ css_grd;

// JS components compiled at compile time
const js_state = @embedFile("js/state.js");
const js_api = @embedFile("js/api.js");
const js_table = @embedFile("js/table-view.js");
const js_grid = @embedFile("js/grid-view.js");
const js_main = @embedFile("js/main.js");
pub const app_js = js_state ++ js_api ++ js_table ++ js_grid ++ js_main;
