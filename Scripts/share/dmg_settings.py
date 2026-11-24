# dmgbuild settings for the shared dmg window.
# Scripts/package-share.sh passes: -D app=<path to .app> -D background=<tiff> -D icon=<icns>
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
app_name = os.path.basename(app)

format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}

# The disk that appears on the desktop shows the app icon.
icon = defines["icon"]  # noqa: F821

# 640 × 400 window: background drawn by Scripts/share/dmg_background.swift (1x + 2x in one tiff).
background = defines["background"]  # noqa: F821
# 432 high = the 32 pt title bar (macOS 26 Finder, measured) + the 400 pt picture.
window_rect = ((200, 140), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = "auto"
include_list_view_settings = "auto"
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
# "ADHD Music", not "ADHD Music.app", even when Finder shows all extensions.
hide_extensions = [app_name]
text_size = 13
icon_size = 128
icon_locations = {app_name: (170, 176), "Applications": (470, 176)}
