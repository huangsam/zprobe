import os

css_dir = "/Users/samhuang/Playground/practice/zprobe/src/web/css"

# Read original files
with open(os.path.join(css_dir, "variables.css"), "r") as f:
    vars_lines = f.readlines()
with open(os.path.join(css_dir, "layout.css"), "r") as f:
    layout_lines = f.readlines()
with open(os.path.join(css_dir, "table.css"), "r") as f:
    table_lines = f.readlines()
with open(os.path.join(css_dir, "grid.css"), "r") as f:
    grid_lines = f.readlines()

# Define new contents
new_variables = "".join(vars_lines[:65])
new_base = (
    "".join(vars_lines[66:]) +
    "".join(layout_lines[0:20]) +
    "".join(layout_lines[32:38]) +
    "".join(layout_lines[788:803])  # Scrollbars
)
new_layout = (
    "".join(layout_lines[20:32]) +
    "".join(layout_lines[39:120])
)
new_components = (
    "".join(layout_lines[120:182]) +
    "".join(layout_lines[514:570]) +
    "".join(layout_lines[767:787]) + # close-btn
    "".join(layout_lines[803:852]) + # lucide icons
    "".join(layout_lines[1178:1278]) + # copy-btn
    "".join(layout_lines[1278:1286]) + # search-highlight
    "".join(layout_lines[1377:1383]) # value-with-action .value
)
new_filters = "".join(layout_lines[182:508])
new_overlays = (
    "".join(layout_lines[570:767]) + # details-drawer, drawer-backdrop
    "".join(layout_lines[852:1121]) + # modal
    "".join(layout_lines[1341:1377]) + # details-drawer animation
    "".join(layout_lines[1383:]) # details-drawer responsive
)
new_catalog_table = (
    "".join(layout_lines[508:514]) + # date-cell
    "".join(table_lines) +
    "".join(layout_lines[1121:1177]) + # pagination
    "".join(layout_lines[1286:1341]) # skeleton loading
)
new_catalog_grid = "".join(grid_lines)

# Write output files
files_to_write = {
    "variables.css": new_variables,
    "base.css": new_base,
    "components.css": new_components,
    "layout.css": new_layout,
    "filters.css": new_filters,
    "overlays.css": new_overlays,
    "catalog-table.css": new_catalog_table,
    "catalog-grid.css": new_catalog_grid,
}

for filename, content in files_to_write.items():
    with open(os.path.join(css_dir, filename), "w") as f:
        f.write(content)

print("CSS refactoring complete.")
