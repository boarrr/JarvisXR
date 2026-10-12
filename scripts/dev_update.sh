#!/bin/sh
# Publish a build for wireless self-update.
#
# Bumps the patch version and publishes to the daemon's update manifest.
#
# NOTE: we ship *debug* builds. Godot's Android release template SIGSEGVs in the
# Vulkan render path on this Horizon build (VkRenderer.onVkDrawFrame ->
# GodotLib.step), so release (~30MB) is not usable yet; debug is ~37MB.
#
# Usage: ./scripts/dev_update.sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
presets="$project_root/client-godot/export_presets.cfg"
project="$project_root/client-godot/project.godot"

name=$(sed -n 's/^version\/name="\(.*\)"$/\1/p' "$presets" | head -1)
code=$(sed -n 's/^version\/code=\([0-9]*\)$/\1/p' "$presets" | head -1)
[ -n "$name" ] || { printf '%s\n' "No version/name in export presets" >&2; exit 2; }
[ -n "$code" ] || code=0

major=${name%%.*}
rest=${name#*.}
minor=${rest%%.*}
patch=${rest##*.}
new_name="$major.$minor.$((patch + 1))"
new_code=$((code + 1))

sed -i '' "s/^version\/name=.*/version\/name=\"$new_name\"/; s/^version\/code=.*/version\/code=$new_code/" "$presets"
if grep -q '^config/version=' "$project"; then
	sed -i '' "s|^config/version=.*|config/version=\"$new_name\"|" "$project"
fi

printf '%s\n' "Publishing $new_name (code $new_code)"
exec "$project_root/scripts/quest.sh" export
