#!/usr/bin/env bash
# Set up Positron with R on SteamOS, for Desktop and Game Mode, without root.
#
#   install.sh [--remove GROUPS] [--sha256 HASH] [--add-to-steam] [VERSION]
#
#   --remove GROUPS   comma-separated list, or "all":
#                     copilot assistant python quarto remote cloud node
#                     locales settings
#   --add-to-steam    from Desktop Mode, add the Game Mode shortcut to Steam
#   --sha256 HASH     check the downloaded .deb
#   VERSION           Positron version, e.g. 2026.11.1-4; re-run to update
#
# Run it from this folder's copy on the Deck; it needs conda-shim.sh and
# Positron next to it. Every step is safe to re-run.
#
# Removing deletes files from the unpacked version folder. A later run that
# removes less unpacks Positron again. Settings and uninstalled extensions
# stay as they are; reinstall extensions from the Extensions view.
#
# Layout on the Deck:
#   ~/Applications/positron-<VERSION>     unpacked app, one per version
#   ~/Applications/positron               symlink to the active version
#   ~/Applications/positron-gamemode/     Steam shortcut target and its log
#   ~/micromamba/envs/r                   R from conda-forge
#   ~/.config/positron-deck/              conda shim, profile backup

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

default_version="2026.11.1-4"
sha256=""
add_to_steam=false
remove_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove) remove_arg="$2"; shift 2 ;;
    --remove=*) remove_arg="${1#--remove=}"; shift ;;
    --sha256) sha256="$2"; shift 2 ;;
    --add-to-steam) add_to_steam=true; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
    *) break ;;
  esac
done
version="${1:-$default_version}"

r_packages=(r-base r-tidyverse)

# ---------------------------------------------------------------- Removal groups
#
# Each group lists built-in extensions (folders under resources/app/extensions),
# bootstrap extensions (installed from extensions/bootstrap on first start;
# dropped from product.json so they aren't reinstalled) and files under
# resources/app.
#
#   copilot     GitHub Copilot Chat and the Copilot CLI binary
#   assistant   Positron Assistant chat, next-edit suggestions, agent skills
#   python      Python support, Jupyter, debugpy, pyrefly, ruff, reticulate,
#               notebook "Debug Cell" (errors without positron-python).
#               SteamOS has no Python; R debugging is separate.
#   quarto      Quarto extension and bundled CLI (~420 MB). To restore: the
#               Quarto extension plus `micromamba install -n r quarto`.
#   remote      SSH, dev containers, tunnels, remote file transfer, HPC modules
#   cloud       Snowflake and Databricks drivers, Posit Connect publisher
#   node        Node.js debugger auto-attach and server-ready
#   locales     non-English UI translations
#   settings    telemetry and update checks off, quieter kernel supervisor,
#               solid cursor, reduced motion, no minimap

all_groups=(copilot assistant python quarto remote cloud node locales settings)

declare -A group_builtin=(
  [copilot]="copilot"
  [assistant]="next-edit-suggestions positron-skills"
  [python]="positron-python positron-runtime-debugger positron-reticulate"
  [remote]="positron-dev-containers open-remote-ssh tunnel-forwarding
            positron-file-transfer positron-environment-modules"
  [cloud]="positron-data-driver-snowflake positron-data-driver-databricks"
  [node]="debug-auto-launch debug-server-ready"
)
declare -A group_bootstrap=(
  [assistant]="posit.assistant"
  [python]="ms-toolsai.jupyter ms-toolsai.jupyter-keymap
            ms-toolsai.jupyter-renderers ms-toolsai.vscode-jupyter-cell-tags
            ms-toolsai.vscode-jupyter-slideshow ms-python.debugpy meta.pyrefly
            charliermarsh.ruff"
  [quarto]="quarto.quarto"
  [cloud]="posit.publisher"
)
declare -A group_files=(
  [copilot]="node_modules.asar.unpacked/@github/copilot-linux-x64"
  [quarto]="quarto"
)

# Always removed: these can't work on SteamOS or Linux.
base_builtin=(
  microsoft-authentication         # needs libwebkit2gtk
  positron-data-driver-odbc        # needs libodbc
)
base_files=(node_modules.asar.unpacked/windows-foreground-love)
base_file_patterns=('*.exe' '*.dll' 'win32-*.node' 'windows.node')

remove_groups=()
if [[ "$remove_arg" == all ]]; then
  remove_groups=("${all_groups[@]}")
elif [[ -n "$remove_arg" ]]; then
  IFS=, read -ra requested <<<"$remove_arg"
  for g in "${all_groups[@]}"; do
    for r in "${requested[@]}"; do
      [[ "$r" == "$g" ]] && remove_groups+=("$g") && break
    done
  done
  for r in "${requested[@]}"; do
    [[ " ${all_groups[*]} " == *" $r "* ]] && continue
    echo "unknown group: $r (choose from: ${all_groups[*]}, or all)" >&2
    exit 1
  done
fi
removing() { [[ " ${remove_groups[*]} " == *" $1 "* ]]; }

# Settings for the "settings" group.
debloat_settings='{
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "extensions.autoCheckUpdates": false,
  "extensions.autoUpdate": false,
  "extensions.ignoreRecommendations": true,
  "workbench.enableExperiments": false,
  "kernelSupervisor.logLevel": "warn",
  "kernelSupervisor.resourceUsagePollInterval": 5000,
  "editor.cursorBlinking": "solid",
  "workbench.reduceMotion": "on",
  "editor.minimap.enabled": false,
  "workbench.startupEditor": "none",
  "npm.autoDetect": "off",
  "task.autoDetect": "off"
}'

apps="$HOME/Applications"
target="$apps/positron-$version"
link="$apps/positron"
gamemode="$apps/positron-gamemode"
cache="$HOME/Downloads/positron"
deck_config="$HOME/.config/positron-deck"
mamba="$HOME/.local/bin/micromamba"
export MAMBA_ROOT_PREFIX="$HOME/micromamba"
r_env="$MAMBA_ROOT_PREFIX/envs/r"
settings="$HOME/.config/Positron/User/settings.json"

step() { printf '\n== %s\n' "$*"; }

ensure_not_running() {
  if pgrep -f "$apps/positron-[^/]*/positron( |$)" >/dev/null \
    || pgrep -f "$link/positron( |$)" >/dev/null; then
    echo "Positron is running; quit it first so files aren't changed under it." >&2
    exit 1
  fi
}

mkdir -p "$apps" "$cache" "$deck_config" "$gamemode" "$HOME/.local/bin" \
  "$HOME/.local/share/applications" \
  "$HOME/.local/share/icons/hicolor/1024x1024/apps"

# ---------------------------------------------------------------- Positron

step "Positron $version"

# A plain directory at $link is an install from before versioned folders.
if [[ -d "$link" && ! -L "$link" ]]; then
  old="$("$link/bin/positron" --version | head -1 | awk '{print $2 "-" $4}')"
  mv "$link" "$apps/positron-$old"
  ln -s "positron-$old" "$link"
fi

# .deck-removed records the groups removed from this version folder. Folders
# from before it existed had every group removed if Copilot is gone.
marker="$target/.deck-removed"
fresh=false
previous=()
if [[ -f "$marker" ]]; then
  read -ra previous <"$marker"
elif [[ -d "$target" && ! -d "$target/resources/app/extensions/copilot" ]]; then
  previous=("${all_groups[@]}")
fi
restore=()
for g in "${previous[@]}"; do
  removing "$g" || restore+=("$g")
done
if [[ -d "$target" && ${#restore[@]} -gt 0 ]]; then
  echo "unpacking again to restore: ${restore[*]}"
  ensure_not_running
  rm -rf "${target:?}"
fi

if [[ -d "$target" ]]; then
  echo "already unpacked"
else
  fresh=true
  deb="$cache/Positron-$version-x64.deb"
  url="https://cdn.posit.co/positron/releases/deb/x86_64/Positron-$version-x64.deb"
  if [[ ! -f "$deb" ]]; then
    echo "downloading $url"
    curl -fL --progress-bar -o "$deb.part" "$url"
    mv "$deb.part" "$deb"
  fi
  if [[ -n "$sha256" ]]; then
    echo "$sha256  $deb" | sha256sum -c -
  fi

  stage="$(mktemp -d "$cache/stage.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  bsdtar -xOf "$deb" 'data.tar*' | bsdtar -xf - -C "$stage"
  mv "$stage/usr/share/positron" "$target"
fi
# The .deb is only needed to unpack; an update downloads the new one.
for old_deb in "$cache"/Positron-*-x64.deb; do
  [[ -f "$old_deb" ]] && rm -f "$old_deb" && echo "removed $(basename "$old_deb")"
done

ln -sfn "positron-$version" "$link"
ln -sf "$link/bin/positron" "$HOME/.local/bin/positron"
cp "$link/resources/app/resources/linux/positron.png" \
  "$HOME/.local/share/icons/hicolor/1024x1024/apps/co.posit.positron.png"

cat > "$HOME/.local/share/applications/co.posit.positron.desktop" <<EOF
[Desktop Entry]
Name=Positron
Comment=A next-generation data science IDE
GenericName=Data Science IDE
Exec=$link/positron %F
Icon=co.posit.positron
Type=Application
StartupNotify=false
StartupWMClass=Positron
Categories=TextEditor;Development;IDE;
MimeType=text/plain;application/x-r;text/x-python;
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=$link/positron --new-window %F
Icon=co.posit.positron
EOF
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
"$link/bin/positron" --version | head -1

# ---------------------------------------------------------------- Debloat

label="${remove_groups[*]}"
step "Remove (${label:-nothing optional})"

if removing settings; then
  # Positron picks these up live, even while running.
  mkdir -p "$(dirname "$settings")"
  python3 -I - "$settings" "$debloat_settings" <<'EOF'
import json, sys, pathlib
p, add = pathlib.Path(sys.argv[1]), json.loads(sys.argv[2])
s = json.loads(p.read_text()) if p.exists() and p.read_text().strip() else {}
s.update(add)
p.write_text(json.dumps(s, indent=2) + "\n")
print("settings:", ", ".join(f"{k}={v}" for k, v in add.items()))
EOF
fi

# Groups this run removes that the folder still has.
added=()
for g in "${remove_groups[@]}"; do
  [[ " ${previous[*]} " == *" $g "* ]] || added+=("$g")
done

if ! $fresh && [[ ${#added[@]} -eq 0 ]]; then
  echo "already done"
else
  ensure_not_running

  builtin_list=("${base_builtin[@]}")
  bootstrap_list=()
  file_list=("${base_files[@]}")
  # Unquoted echo joins the multi-line group entries onto one line for read.
  for g in "${remove_groups[@]}"; do
    read -ra items <<<"$(echo ${group_builtin[$g]:-})"; builtin_list+=("${items[@]}")
    read -ra items <<<"$(echo ${group_bootstrap[$g]:-})"; bootstrap_list+=("${items[@]}")
    read -ra items <<<"$(echo ${group_files[$g]:-})"; file_list+=("${items[@]}")
  done

  ext="$target/resources/app/extensions"
  before="$(du -sm "$target" | cut -f1)"
  for name in "${builtin_list[@]}"; do
    [[ -d "$ext/$name" ]] && rm -rf "${ext:?}/$name" && echo "removed built-in $name"
  done

  python3 -I - "$target/resources/app/product.json" "${bootstrap_list[@]}" <<'EOF'
import json, sys, pathlib
p, drop = pathlib.Path(sys.argv[1]), {x.lower() for x in sys.argv[2:]}
d = json.loads(p.read_text())
kept = [e for e in d.get("bootstrapExtensions", []) if e["name"].lower() not in drop]
if len(kept) != len(d.get("bootstrapExtensions", [])):
    d["bootstrapExtensions"] = kept
    p.write_text(json.dumps(d, indent="\t"))
    print("product.json: bootstrap list trimmed to", len(kept))
EOF
  shopt -s nocaseglob nullglob
  for id in "${bootstrap_list[@]}"; do
    for vsix in "$ext/bootstrap/$id"-[0-9]*.vsix; do
      rm -f "$vsix" && echo "removed bootstrap $(basename "$vsix")"
    done
    if [[ -n "$(echo "$HOME"/.positron/extensions/"$id"-[0-9]*)" ]]; then
      # Uninstalling a pack can remove its members first; not-found is fine.
      "$link/bin/positron" --uninstall-extension "$id" 2>&1 | tail -1 || true
    fi
  done
  shopt -u nocaseglob nullglob

  for rel in "${file_list[@]}"; do
    [[ -e "$target/resources/app/$rel" ]] && rm -rf "${target:?}/resources/app/$rel" \
      && echo "removed $rel"
  done
  for pattern in "${base_file_patterns[@]}"; do
    find "$target/resources/app" -type f -name "$pattern" -print -delete \
      | sed "s|^$target/resources/app/|removed |"
  done

  if removing locales; then
    find "$target/locales" -name '*.pak' ! -name 'en-US.pak' -delete
    echo "removed non-English locales"
  fi

  echo "size: ${before} MB -> $(du -sm "$target" | cut -f1) MB"
fi
echo "${remove_groups[*]}" >"$marker"

# ---------------------------------------------------------------- R

step "micromamba"
if [[ -x "$mamba" ]]; then
  echo "already installed: $("$mamba" --version)"
else
  curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest \
    | bsdtar -xf - -C "$HOME/.local" bin/micromamba
  "$mamba" --version
fi

step "R environment (${r_packages[*]})"
if [[ -x "$r_env/bin/R" ]]; then
  echo "already exists: $("$r_env/bin/R" --version | head -1)"
else
  echo "creating; takes a few minutes"
  "$mamba" create -y -q -n r -c conda-forge "${r_packages[@]}"
  "$r_env/bin/R" --version | head -1
fi
# The env hard-links into pkgs/; cleaning drops the downloaded archives and
# unlinked leftovers only.
"$mamba" clean --all -y -q >/dev/null && echo "package cache cleaned"

# Positron runs `conda activate <env>` for conda-based R; SteamOS has no
# conda, so a login-shell function forwards it to micromamba.
step "conda shim"
cp "$here/conda-shim.sh" "$deck_config/conda-shim.sh"
if grep -q "positron-deck/conda-shim.sh" "$HOME/.bash_profile" 2>/dev/null; then
  echo "already sourced from ~/.bash_profile"
else
  backup="$deck_config/bash_profile.backup-$(date +%F)"
  [[ -f "$HOME/.bash_profile" && ! -e "$backup" ]] && cp "$HOME/.bash_profile" "$backup"
  printf '\n# Positron on Steam Deck: conda -> micromamba\n[[ -f ~/.config/positron-deck/conda-shim.sh ]] && . ~/.config/positron-deck/conda-shim.sh\n' \
    >> "$HOME/.bash_profile"
  echo "added to ~/.bash_profile"
fi
bash -l -c "conda activate '$r_env' && command -v R"

step "Positron settings"
mkdir -p "$(dirname "$settings")"
python3 -I - "$settings" "$r_env/bin/R" <<'EOF'
import json, sys, pathlib
p, r = pathlib.Path(sys.argv[1]), sys.argv[2]
s = json.loads(p.read_text()) if p.exists() and p.read_text().strip() else {}
binaries = s.setdefault("positron.r.customBinaries", [])
if r not in binaries:
    binaries.append(r)
p.write_text(json.dumps(s, indent=2) + "\n")
print("positron.r.customBinaries:", binaries)
EOF

# The left-stick radial menu sends Ctrl+Shift+Alt+A..L; these bindings turn
# each chord into an R snippet. Entries on other keys are kept.
step "Snippet keys"
python3 -I - "$(dirname "$settings")/keybindings.json" "$here/snippet-keys.json" <<'EOF'
import json, sys, pathlib
p, src = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
ours = json.loads(src.read_text())
text = p.read_text() if p.exists() else ""
try:
    current = json.loads(text) if text.strip() else []
except json.JSONDecodeError:
    print(f"skipped: {p} has comments or isn't plain JSON; merge {src} by hand")
    sys.exit(0)
taken = {b["key"] for b in ours}
merged = [b for b in current if b.get("key") not in taken] + ours
p.write_text(json.dumps(merged, indent=2, ensure_ascii=False) + "\n")
print(f"{len(ours)} snippet keys in {p}")
EOF

# ---------------------------------------------------------------- Game Mode

step "Game Mode launcher"
install -m 755 "$here/Positron" "$gamemode/Positron"
echo "$gamemode/Positron"

# Steam lists files in config/<shortcut name>/ under "Your Layouts".
step "Controller layout"
layout="$here/../steam/positron_deck_0.vdf"
configs="$HOME/.local/share/Steam/steamapps/common/Steam Controller Configs"
if [[ -f "$layout" && -d "$configs" ]]; then
  for account in "$configs"/*/config; do
    mkdir -p "$account/positron"
    cp "$layout" "$account/positron/positron_deck_0.vdf"
    echo "$account/positron/positron_deck_0.vdf"
  done
else
  echo "skipped (no layout file or no Steam controller configs)"
fi

# Steam reads custom art from userdata/<account>/config/grid/, named by the
# shortcut's app ID, which only exists once Positron is in the library.
step "Library artwork"
art="$here/../steam/artwork"
install -m 644 "$art/icon.png" "$gamemode/icon.png" 2>/dev/null || true
if [[ -f "$art/hero.png" ]]; then
  python3 -I - "$art" "$gamemode/Positron" <<'EOF'
import pathlib, re, shutil, struct, sys
art, exe = pathlib.Path(sys.argv[1]), sys.argv[2]
names = {"portrait.png": "{}p.png", "landscape.png": "{}.png",
         "hero.png": "{}_hero.png", "logo.png": "{}_logo.png"}
entry = re.compile(rb"\x02appid\x00(.{4})\x01appname\x00[^\x00]*\x00\x01exe\x00([^\x00]*)\x00",
                   re.DOTALL | re.IGNORECASE)
found = False
for vdf in pathlib.Path.home().glob(".local/share/Steam/userdata/*/config/shortcuts.vdf"):
    for raw_id, raw_exe in entry.findall(vdf.read_bytes()):
        if raw_exe.decode(errors="replace").strip('"') != exe:
            continue
        appid = struct.unpack("<I", raw_id)[0]
        grid = vdf.parent / "grid"
        grid.mkdir(exist_ok=True)
        for src, pattern in names.items():
            shutil.copy(art / src, grid / pattern.format(appid))
        print(f"{grid}/{appid}*.png")
        found = True
if not found:
    print("skipped (Positron is not in the Steam library yet; re-run after adding it)")
EOF
else
  echo "skipped (no rendered artwork in steam/artwork)"
fi

if $add_to_steam; then
  encoded="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$gamemode/Positron")"
  # steamos-add-to-steam rejects scripts (KDE reports text/x-shellscript),
  # so send Steam the same URL it would.
  touch /tmp/addnonsteamgamefile
  steam "steam://addnonsteamgame/$encoded"
  echo "sent to Steam; check the library for \"Positron\""
fi

cat <<EOF

Done.
- Desktop Mode: Positron is in the app menu.
- Game Mode: add $gamemode/Positron as a non-Steam game if it isn't in
  the library (or rerun with --add-to-steam from Desktop Mode), then set its
  controller layout to Your Layouts > Positron Deck.
- Icon: Properties > Shortcut, click the icon, pick $gamemode/icon.png.
  Restart Steam if the library art doesn't show.
- New folders open in Restricted Mode; trust them to start R.
EOF
