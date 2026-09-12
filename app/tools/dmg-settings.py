"""Finder metadata for the drag-to-install disk image; no Finder process is used."""

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [defines["app"], (defines["license"], ".dmgbuild-LICENSE.txt")]  # dmgbuild's -D options.
symlinks = {"Applications": "/Applications"}
# Do not add FinderInfo to the signed app to hide its extension; that invalidates
# strict signature verification. Finder already treats the bundle as an app.
icon_locations = {"Tursora.app": (140, 120), "Applications": (500, 120)}
background = "builtin-arrow"
window_rect = ((100, 100), (640, 280))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 16
icon_size = 128
