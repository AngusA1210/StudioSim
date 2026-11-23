# How StudioSim-macOS.dmg looks when it is opened: a window with StudioSim and the Applications folder side by side
# and nothing else (no toolbar, sidebar or status bar), to drag the one onto the other; the disk's icon StudioSim's.
# tools/package.sh hands it to dmgbuild (https://github.com/dmgbuild/dmgbuild), which writes the window's layout
# itself rather than asking Finder to, so it is made the same on GitHub's computers as on a Mac at a desk.
#
#   dmgbuild -s tools/dmg_settings.py -D app=<path to StudioSim.app> "StudioSim <version>" <out.dmg>
import os

app = defines["app"]  # noqa: F821 (given by dmgbuild)
name = os.path.basename(app)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
# (not hide_extensions: it sets the app's Finder info, which a strict check of its signature refuses)
icon = os.path.join(app, "Contents", "Resources", "icon.icns")

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

window_rect = ((240, 160), (560, 340))
arrange_by = None
icon_size = 128
text_size = 14
icon_locations = {name: (150, 150), "Applications": (410, 150)}
