#!/bin/sh
# call syswrapper.lua from wherever openUF is installed: the package puts it
# under /usr/lib/openuf, install.sh under /opt/openuf. The controller's SSH
# adoption runs this by name, so it has to find the tree on its own.
for d in /usr/lib/openuf /opt/openuf; do
	[ -f "$d/hook/syswrapper.lua" ] && exec lua "$d/hook/syswrapper.lua" "$@"
done
echo "syswrapper.sh: openUF is not installed (no /usr/lib/openuf or /opt/openuf)" >&2
exit 1
