#!/bin/bash
# Installs a set of apps and tools while Gandalf stirs his cauldron on screen. Apps that are
# already installed are skipped, every step that fails is tried a second time, failures are
# logged to error_log.txt and everything is summarized at the end.
VERSION="4.0.0"
echo -e "\e[91mlinux_apps_setup_wizard_v${VERSION}\e[0m"

usage() {
    cat <<'EOF'
Usage: sudo bash linux_apps_setup_wizard.sh [options]

Options:
  --no-animation   plain text output: no animation and no progress bar
  --ascii          draw Gandalf with plain ASCII characters (no half-block pixel art)
  --stacked        keep the output below the picture instead of beside it (wide terminals)
  --demo           play the animation with fake tasks (nothing is installed)
  -h, --help       show this help
EOF
}

DEMO=0
for arg in "$@"; do
    case "$arg" in
        --no-animation) NO_ANIMATION=1 ;;
        --ascii)        ASCII_ONLY=1 ;;
        --stacked)      STACKED_ONLY=1 ;;
        --demo)         DEMO=1 ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

# A failure anywhere inside a pipeline counts as a failure of the whole pipeline
set -o pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
ERROR_LOG="error_log.txt"               # collects every failure (appended on each run)
MAX_ATTEMPTS=2                          # each step runs once and, if it fails, once more
RETRY_DELAY="${RETRY_DELAY:-5}"         # seconds to wait before the second attempt
WGET_OPTS=(-nv --timeout=30 --tries=3)  # show errors, don't hang on a stalled download
OUTPUT_LOG="${OUTPUT_LOG:-setup_output.log}"  # everything the commands print (kept while the animation is on)
(( DEMO )) && { ERROR_LOG=/dev/null; OUTPUT_LOG=/dev/null; }
ROCKYOU_GZ="${ROCKYOU_GZ:-/usr/share/wordlists/rockyou.txt.gz}"
SECLISTS_DIR="${SECLISTS_DIR:-/usr/share/seclists}"
BRAVE_KEYRING="/usr/share/keyrings/brave-browser-archive-keyring.gpg"

FAILED_STEPS=()      # steps that failed on every attempt
RECOVERED_STEPS=()   # steps that failed once but worked on the second attempt
SKIPPED_APPS=()      # apps that were already installed
CURRENT_STEP=""      # step that is running right now
INTERRUPTED=0

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

# Append a timestamped line to the error log
write_log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $level: $*" >> "$ERROR_LOG"
}

# Function to log errors in red and keep them in the error log
log_error() {
    local error_message="$1"
    printf '\e[91m%s\e[0m\n' "$error_message"  # Print in red
    write_log ERROR "$error_message"
}

# Function to log messages in green
log_success() {
    local success_message="$1"
    printf '\e[32m%s\e[0m\n' "$success_message"  # Print in green
}

# Function to log messages in yellow
log_warning() {
    local warning_message="$1"
    printf '\e[93m%s\e[0m\n' "$warning_message"  # Print in yellow
}

# Create a log file to collect errors
if ! touch "$ERROR_LOG" 2>/dev/null; then
    log_warning "Cannot write to $ERROR_LOG, errors will only be shown on screen."
    ERROR_LOG=/dev/null
fi
write_log INFO "---- linux_apps_setup_wizard v$VERSION started ----"

# ----------------------------------------------------------------------------
# Retry logic
# ----------------------------------------------------------------------------

# apt and dpkg run through these two. While the animation is on they must not open
# full-screen dialogs or draw their own progress bar, because that would wreck the screen.
APT_ENV=()
APT_FLAGS=()
sudo_apt()  { sudo "${APT_ENV[@]}" apt "${APT_FLAGS[@]}" "$@"; }
sudo_dpkg() { sudo "${APT_ENV[@]}" dpkg "$@"; }

# Recovery action that runs before a failed package step is tried again
fix_broken_deps() {
    log_warning "Fixing broken dependencies..."
    sudo_dpkg --configure -a
    sudo_apt --fix-broken install -y
}

# run_step [-r recovery_function] "Description" command [args...]
#   Runs the command. If it fails, the recovery function (if given) runs, the
#   script waits RETRY_DELAY seconds and the command is tried one more time.
#   Returns 0 on success and 1 if every attempt failed. A failure is logged but
#   never stops the script, so the next steps still run.
run_step() {
    local recovery=""
    if [[ "$1" == "-r" ]]; then
        recovery="$2"
        shift 2
    fi
    local description="$1"
    shift

    local attempt rc=0
    CURRENT_STEP="$description"
    for (( attempt = 1; attempt <= MAX_ATTEMPTS; attempt++ )); do
        if (( attempt == 1 )); then
            log_warning "$description..."
        else
            log_warning "$description (attempt $attempt of $MAX_ATTEMPTS)..."
        fi

        "$@"
        rc=$?

        if (( rc == 0 )); then
            if (( attempt > 1 )); then
                RECOVERED_STEPS+=("$description")
            fi
            log_success "$description: done!"
            CURRENT_STEP=""
            return 0
        fi

        write_log WARN "$description failed with exit code $rc (attempt $attempt of $MAX_ATTEMPTS): $*"
        if (( attempt < MAX_ATTEMPTS )); then
            log_warning "$description failed (exit code $rc), trying again in $RETRY_DELAY seconds..."
            if [[ -n "$recovery" ]] && ! "$recovery"; then
                write_log WARN "Recovery action $recovery for \"$description\" also failed"
            fi
            sleep "$RETRY_DELAY"
        fi
    done

    FAILED_STEPS+=("$description")
    log_error "$description FAILED after $MAX_ATTEMPTS attempts (exit code $rc): $*"
    CURRENT_STEP=""
    return 1
}

# apt_install "Name" package...
apt_install() {
    local name="$1"
    shift
    run_step -r fix_broken_deps "Installing $name" sudo_apt install -y "$@"
}

# download_file "Name" url output_file
download_file() {
    local name="$1" url="$2" output="$3"
    if ! run_step "Downloading $name" wget "${WGET_OPTS[@]}" "$url" -O "$output"; then
        rm -f "$output"  # don't leave a partial download behind
        return 1
    fi
}

# install_deb_from_url "Name" url file.deb [cleanup]
#   Downloads a .deb package and installs it. The install is skipped if the
#   download failed. Pass "cleanup" to delete the package after a successful install.
install_deb_from_url() {
    local name="$1" url="$2" file="$3" cleanup="$4"

    if ! download_file "$name" "$url" "$file"; then
        log_warning "Skipping the installation of $name because the download failed."
        return 1
    fi

    run_step -r fix_broken_deps "Installing $name" sudo_dpkg --install "$file" || return 1

    if [[ "$cleanup" == "cleanup" ]]; then
        log_warning "Deleting downloaded $name package..."
        rm -f "$file"
    fi
}

# ----------------------------------------------------------------------------
# Skipping apps that are already installed
# ----------------------------------------------------------------------------

# True if the apt package is installed (not just removed with its config left behind)
package_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}\n' "$1" 2>/dev/null)" == "installed" ]]
}

# is_installed name...
#   True if any of the names is an installed apt package or a command on the PATH.
#   A name that starts with / is a file or directory that has to exist instead.
is_installed() {
    local item
    for item in "$@"; do
        if [[ "$item" == /* ]]; then
            [[ -e "$item" ]] && return 0
        elif package_installed "$item" || command -v "$item" > /dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# skip_if_installed "App name" name...
#   Succeeds (after saying so) when the app is already installed, so its download
#   and install steps can be skipped:   skip_if_installed "App" name... || install_app
skip_if_installed() {
    local app="$1"
    shift
    is_installed "$@" || return 1
    log_warning "$app is already installed, skipping."
    write_log INFO "Skipped $app: already installed"
    SKIPPED_APPS+=("$app")
    return 0
}

# Directory where "go install" puts the programs it builds
go_bin_dir() {
    local dir
    dir="$(go env GOBIN 2>/dev/null)"
    if [[ -z "$dir" ]]; then
        dir="$(go env GOPATH 2>/dev/null)"
        dir="${dir:+${dir%%:*}/bin}"
    fi
    echo "$dir"
}

# ----------------------------------------------------------------------------
# THE ANIMATION - nothing in here installs anything, you can skip reading this part
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Animation: Gandalf stirring his cauldron (top half of the screen), the output of the
# commands (bottom half, scrolls) and a progress bar (last line).
#
# How it works: the screen is split with a terminal "scroll region", so command output only
# scrolls in the lower part. A background process draws the animation in the upper part. Each
# thing it draws is ONE write that saves the cursor, draws and restores the cursor, so it can
# never scramble the text the commands print at the same time.
# ----------------------------------------------------------------------------
ESC=$'\e'
UI_ACTIVE=0          # 1 while the animated screen is on
UI_DIR=""            # temp dir shared with the animation process
ANIM_PID=""
TEE_PID=""
TICK="${TICK:-0.15}" # seconds per animation frame
TASK_NUM=0           # which task is running (for the progress bar)
TOTAL_TASKS=0
SMALL_W=54; SMALL_H=11   # size of the scenes below (keep in sync with scene_small / scene_large)
LARGE_W=72; LARGE_H=18
PIXLARGE_W=72; PIXLARGE_H=18   # the pixel-art scenes (scene_pixlarge, scene_pixmed)
PIXMED_W=56; PIXMED_H=14
SIDE_NAMES=(pixsideL pixside pixsidem pixsides)   # the pictures of the side-by-side layout, biggest first
SIDE_WS=(176 88 66 44); SIDE_HS=(72 36 27 18)   # their size in columns and rows
SIDE_LEFT=(60 44 40 36)                 # narrowest output panel that still reads well next to each of them
SC_ZOOM=1                               # 2 while scene_pixsideL builds the double-size picture from scene_pixside
LAYOUT=stacked                 # stacked: picture above the output / side: output left, picture right
SMOKE_MAXH=14                  # tallest smoke plume (rows)
PANEL_POLL="${PANEL_POLL:-0.1}"    # seconds the output panel waits for new text before it looks at the layout again

declare -A SGR=(     # colour letters used by the art -> terminal colour codes
    [.]=$'\e[0m'  [w]=$'\e[97m' [g]=$'\e[37m' [d]=$'\e[90m'
    [r]=$'\e[31m' [R]=$'\e[91m' [y]=$'\e[33m' [Y]=$'\e[93m'
    [G]=$'\e[32m' [L]=$'\e[92m' [b]=$'\e[34m' [B]=$'\e[94m'
    [c]=$'\e[36m' [C]=$'\e[96m' [m]=$'\e[35m' [M]=$'\e[95m'
)
WOBBLE=(0 1 1 2 2 2 1 1 0 -1 -1 -2 -2 -2 -1 -1)   # sideways sway of the smoke

# Colours of the pixel-art scene: <letter><xterm 256-colour number>, used by the picture in scene_pixlarge
PIXPAL="a22 b23 c28 d35 e47 f52 g58 h85 i88 j94 k115 l121 m130 n136 o137 p157 q160 r180 s187 t202 u208 v214 w220 x223 y226 z230 A233 B234 C235 D236 E237 F238 G239 H240 I241 J242 K243 L244 M245 N246 O247 P248 Q250 R251 S252 T255"
declare -A PFG PBG
ui_set_palette() {                      # ui_set_palette ["<letter><colour> ..."]   (default: PIXPAL above)
    local tok
    PFG=(); PBG=()
    for tok in ${1:-$PIXPAL}; do
        PFG[${tok:0:1}]=$'\e[38;5;'${tok:1}m
        PBG[${tok:0:1}]=$'\e[48;5;'${tok:1}m
    done
}
ui_set_palette
GREEN_SMOKE=(121 85 48 41 35 29 23)    # fresh magic smoke is bright, old smoke fades
SMOKE_GLYPHS=("▓" "▒" "░" "·")
SPARK_GLYPHS=("*" "+" "·")
SPARK_COLORS=(229 192 114)

# Paint one row of art. ui_paint "text" "colour letters"  ->  REPLY
ui_paint() {
    local txt=$1 col=$2 out="" prev="" ch c i n=${#1}
    for (( i = 0; i < n; i++ )); do
        ch=${txt:i:1}
        if [[ $ch == " " ]]; then out+=" "; continue; fi
        c=${col:i:1}
        [[ -z $c ]] && c=.
        if [[ $c != "$prev" ]]; then out+=${SGR[$c]}; prev=$c; fi
        out+=$ch
    done
    REPLY=$out$'\e[0m'
}

# Colour letters for a sprite row, from the sprite's colour spec  ->  REPLY
#   "rows:YR"  one colour per row of the sprite
#   "=g@Y/y"   pairs of  <character><colour>
ui_letters() {
    local txt=$1 spec=$2 row=$3 out="" ch let i j n=${#1}
    if [[ $spec == rows:* ]]; then
        let=${spec:5+row:1}
        [[ -z $let ]] && let=.
        for (( i = 0; i < n; i++ )); do out+=$let; done
    else
        for (( i = 0; i < n; i++ )); do
            ch=${txt:i:1}; let=.
            for (( j = 0; j < ${#spec}; j += 2 )); do
                if [[ ${spec:j:1} == "$ch" ]]; then let=${spec:j+1:1}; break; fi
            done
            out+=$let
        done
    fi
    REPLY=$out
}

# Add an animated piece to the scene.
#   ui_add_sprite <row> <col> <ticks per frame> <seq|rand> "<frames, separated by -- lines>" "<colour spec>"
ui_add_sprite() {
    local idx=$NSPR line i f=0 r=0 h=0 w=0 nf=1 pad
    local -a lines
    mapfile -t lines <<< "$5"
    for line in "${lines[@]}"; do                       # size of the sprite
        if [[ $line == "--" ]]; then nf=$(( nf + 1 )); continue; fi
        (( ${#line} > w )) && w=${#line}
    done
    for line in "${lines[@]}"; do
        [[ $line == "--" ]] && break
        h=$(( h + 1 ))
    done
    SPR_R[idx]=$1; SPR_C[idx]=$2; SPR_PER[idx]=$3; SPR_MODE[idx]=$4
    SPR_H[idx]=$h; SPR_N[idx]=$nf; SPR_LAST[idx]=-1; SPR_PIX[idx]=0
    SPR_OFF[idx]=${#SPR_OUT[@]}
    for line in "${lines[@]}"; do                       # paint every row once, now
        if [[ $line == "--" ]]; then f=$(( f + 1 )); r=0; continue; fi
        printf -v line '%-*s' "$w" "$line"
        ui_letters "$line" "$6" "$r"
        ui_paint "$line" "$REPLY"
        SPR_OUT[SPR_OFF[idx] + f * h + r]=$REPLY
        r=$(( r + 1 ))
    done
    NSPR=$(( NSPR + 1 ))
}

# Can this terminal show the pixel-art scene? It needs UTF-8 (block characters) and 256 colours.
ui_pixel_ok() {
    [[ -z $ASCII_ONLY ]] || return 1
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
        *) return 1 ;;
    esac
    [[ $TERM == *256color* || $COLORTERM == truecolor || $COLORTERM == 24bit ]]
}

# Turn pixel art into terminal text: two rows of pixels become one row of half-block characters.
#   ui_pix_block "<pixel rows>" <width>  ->  PIX_ROWS  (one string per terminal row)
#                                            PIX_CELLS (one self-contained string per character cell)
ui_pix_block() {
    local -a px
    local w=$2 r x t b top bot glyph fg bg row cell curfg curbg nrows
    mapfile -t px <<< "$1"
    nrows=$(( ${#px[@]} / 2 ))
    PIX_ROWS=(); PIX_CELLS=()
    for (( r = 0; r < nrows; r++ )); do
        top=${px[2 * r]}; bot=${px[2 * r + 1]}
        row=""; curfg=""; curbg=""
        for (( x = 0; x < w; x++ )); do
            t=${top:x:1}; b=${bot:x:1}
            if   [[ $t == . && $b == . ]]; then glyph=" ";  fg="";  bg=default
            elif [[ $b == . ]];            then glyph="▀"; fg=$t; bg=default
            elif [[ $t == . ]];            then glyph="▄"; fg=$b; bg=default
            elif [[ $t == "$b" ]];         then glyph="█"; fg=$t; bg=any
            else                                glyph="▀"; fg=$t; bg=$b
            fi
            cell=""
            [[ -n $fg ]] && cell+=${PFG[$fg]}
            [[ $bg != default && $bg != any ]] && cell+=${PBG[$bg]}
            PIX_CELLS[r * w + x]=$cell$glyph$'\e[0m'
            if [[ -n $fg && $fg != "$curfg" ]]; then row+=${PFG[$fg]}; curfg=$fg; fi    # keep the colour codes short
            if [[ $bg == default ]]; then
                if [[ -n $curbg ]]; then row+=$'\e[49m'; curbg=""; fi
            elif [[ $bg != any && $bg != "$curbg" ]]; then
                row+=${PBG[$bg]}; curbg=$bg
            fi
            row+=$glyph
        done
        PIX_ROWS[r]=$row$'\e[0m'
    done
}

# Add an animated piece of pixel art to the scene.
#   ui_add_psprite <row> <col> <ticks per frame> <seq|rand> "<frames, separated by -- lines>" [0 = smoke never reaches it]
ui_add_psprite() {
    local idx=$NSPR line f=0 w h=0 r c frame=""
    local -a lines
    if (( SC_ZOOM == 2 )); then ui_zoom_text "$5"; set -- $(( $1 * 2 )) $(( $2 * 2 )) "$3" "$4" "$REPLY" "$6"; fi
    mapfile -t lines <<< "$5"
    w=${#lines[0]}
    SPR_R[idx]=$1; SPR_C[idx]=$2; SPR_PER[idx]=$3; SPR_MODE[idx]=$4
    SPR_PIX[idx]=1; SPR_W[idx]=$w; SPR_LAST[idx]=-1; SPR_SYNC[idx]=${6:-1}
    SPR_OFF[idx]=${#SPR_OUT[@]}; SPR_COFF[idx]=${#SPR_CELL[@]}
    for line in "${lines[@]}" "--"; do                  # the extra "--" ends the last frame
        if [[ $line == "--" ]]; then
            ui_pix_block "${frame%$'\n'}" "$w"
            h=${#PIX_ROWS[@]}
            for (( r = 0; r < h; r++ )); do
                SPR_OUT[SPR_OFF[idx] + f * h + r]=${PIX_ROWS[r]}
                for (( c = 0; c < w; c++ )); do
                    SPR_CELL[SPR_COFF[idx] + (f * h + r) * w + c]=${PIX_CELLS[r * w + c]}
                done
            done
            f=$(( f + 1 )); frame=""
        else
            frame+=$line$'\n'
        fi
    done
    SPR_H[idx]=$h; SPR_N[idx]=$f
    NSPR=$(( NSPR + 1 ))
}

# Every pixel of a picture (text rows of palette letters, frames separated by "--" lines) becomes 2x2 pixels  ->  REPLY
ui_zoom_text() {
    local -a rows
    local line out="" i n c dbl
    mapfile -t rows <<< "$1"
    for line in "${rows[@]}"; do
        if [[ $line == "--" ]]; then out+=$line$'\n'; continue; fi
        dbl=""; n=${#line}
        for (( i = 0; i < n; i++ )); do c=${line:i:1}; dbl+=$c$c; done
        out+=$dbl$'\n'$dbl$'\n'
    done
    REPLY=${out%$'\n'}
}

# The double-size picture: scene_pixside with every pixel doubled (nothing extra to store in the script)
scene_pixsideL() {
    local s row col drift hcfg kind
    local -a src=()
    SC_ZOOM=2
    scene_pixside
    ui_zoom_text "$SC_PIX"; SC_PIX=$REPLY
    SC_W=$(( SC_W * 2 )); SC_H=$(( SC_H * 2 ))
    for s in "${SC_SOURCES[@]}"; do
        read -r row col drift hcfg kind <<< "$s"
        (( hcfg < 99 )) && hcfg=$(( hcfg * 2 ))
        src+=("$(( row * 2 )) $(( col * 2 )) $drift $hcfg $kind")
    done
    SC_SOURCES=("${src[@]}")
    SC_ZOOM=1
}

# Big enough for the side-by-side layout (output on the left, the big picture on the right)?
# (The output panel cuts text by characters, so bash itself must be in a UTF-8 locale, not only the terminal.)
ui_side_fits() {
    local glyph="▀"
    ui_pixel_ok && (( ${#glyph} == 1 )) && ui_side_pick
}

# The biggest picture that fits next to an output panel  ->  SIDE_I (0 = biggest, -1 = none; the exit status says so too)
ui_side_pick() {
    local i
    SIDE_I=-1
    for i in 0 1 2 3; do
        if (( L >= SIDE_HS[i] + 2 && C >= SIDE_WS[i] + 3 + SIDE_LEFT[i] )); then SIDE_I=$i; return 0; fi
    done
    return 1
}

ui_layout() {
    if [[ $LAYOUT == side ]]; then ui_layout_side; else ui_layout_stacked; fi
}

# Stacked: the picture gets the top half of the screen, the output scrolls below it.
ui_layout_stacked() {
    ANIM_ROWS=$(( L / 2 ))
    SCENE=none
    if   ui_pixel_ok && (( ANIM_ROWS >= PIXLARGE_H + 1 && C >= PIXLARGE_W + 2 )); then SCENE=pixlarge
    elif ui_pixel_ok && (( ANIM_ROWS >= PIXMED_H + 1 && C >= PIXMED_W + 2 )); then SCENE=pixmed
    elif (( ANIM_ROWS >= LARGE_H + 1 && C >= LARGE_W + 2 )); then SCENE=large
    elif (( ANIM_ROWS >= SMALL_H + 1 && C >= SMALL_W + 2 )); then SCENE=small
    elif ui_pixel_ok && (( ANIM_ROWS >= 19 && C >= 46 )); then SCENE=pixsides      # tiny pictures: narrow terminals, phones
    elif ui_pixel_ok && (( ANIM_ROWS >= 14 && C >= 34 )); then SCENE=pixt2
    elif ui_pixel_ok && (( ANIM_ROWS >= 10 && C >= 24 )); then SCENE=pixt3
    fi
    [[ $SCENE == none ]] && ANIM_ROWS=0                 # too small: progress bar only
    REGION_TOP=$(( ANIM_ROWS + 1 ))                     # output scrolls between these rows
    REGION_BOT=$(( L - 1 ))
    AREA_R0=1; AREA_R1=$(( ANIM_ROWS - 1 )); AREA_C0=1; AREA_C1=$(( C - 1 ))   # where smoke may be drawn
    SMOKE_MAXH=14
}

# Side by side: the output panel on the left (about 42% of the width), a thin divider, the picture on the right.
ui_layout_side() {
    SCENE=none
    if ui_side_pick; then
        SCENE=${SIDE_NAMES[SIDE_I]}
        LP_W=$(( C * 42 / 100 ))
        (( LP_W > C - SIDE_WS[SIDE_I] - 3 )) && LP_W=$(( C - SIDE_WS[SIDE_I] - 3 ))
        (( LP_W < SIDE_LEFT[SIDE_I] )) && LP_W=${SIDE_LEFT[SIDE_I]}
        RP_COL=$(( LP_W + 2 )); RP_W=$(( C - LP_W - 1 ))
    else                                                # too small for the picture: only the output, over the whole width
        LP_W=$C; RP_COL=$(( C + 1 )); RP_W=0
    fi
    PANEL_COL=1; PANEL_ROW=2; PANEL_W=$LP_W; PANEL_H=$(( L - 2 ))   # output rows 2 .. L-1 (row 1 = title, row L = progress bar)
    AREA_R0=1; AREA_R1=$(( L - 1 )); AREA_C0=$RP_COL; AREA_C1=$(( C - 1 ))
    ANIM_ROWS=0; REGION_TOP=1; REGION_BOT=$(( L - 1 ))
    SMOKE_MAXH=24
}

# Where the scene stands on the screen
ui_place_scene() {
    if [[ $LAYOUT == side ]]; then
        ART_TOP=$(( L - SC_H ))                         # on the bottom row above the progress bar
        ART_X=$(( RP_COL - 1 + (RP_W - SC_W) / 2 ))
    else
        ART_TOP=$(( ANIM_ROWS - SC_H ))                 # on the separator line
        ART_X=$(( (C - SC_W) / 2 ))
    fi
}

# A title line of the given width: dashes, the name and version in the middle  ->  REPLY
ui_header_line() {
    local w=$1 title=" linux_apps_setup_wizard v$VERSION " l r dl dr
    if (( w < ${#title} + 4 )); then title=${title:0:w}; l=0; r=0
    else l=$(( (w - ${#title}) / 2 )); r=$(( w - ${#title} - l )); fi
    printf -v dl '%*s' "$l" ''; printf -v dr '%*s' "$r" ''
    REPLY=$'\e[90m'${dl// /-}$'\e[97m'$title$'\e[90m'${dr// /-}$'\e[0m'
}

# Tell the output panel where it lives (a new generation number makes it redraw)
ui_publish_layout() {
    printf '%s %s %s %s %s .\n' "$LAYOUT_GEN" "$PANEL_COL" "$PANEL_ROW" "$PANEL_W" "$PANEL_H" > "$UI_DIR/layout"
}

# Load the scene that fits (see ui_layout) and work out where everything goes on screen.
ui_load_scene() {
    local i src row col drift hcfg kind avail
    local -a parts bgt bgc
    NSPR=0; NSRC=0; NPREV=0
    SPR_R=(); SPR_C=(); SPR_PER=(); SPR_MODE=(); SPR_H=(); SPR_N=(); SPR_LAST=(); SPR_OFF=(); SPR_OUT=()
    SPR_PIX=(); SPR_W=(); SPR_COFF=(); SPR_CELL=(); SPR_SYNC=(); CELLS=(); SC_KIND=ascii
    SRC_R=(); SRC_C=(); SRC_DRIFT=(); SRC_H=(); SRC_K=(); SRC_KIND=()
    PREV_R=(); PREV_C=()
    SEP_LINE=""; HEADER_LINE=""
    ui_set_palette                                      # a scene may switch to its own colours
    SC_ZOOM=1
    if [[ $SCENE != none ]]; then
        "scene_$SCENE"
        ui_place_scene
        BGT=(); BGC=(); BG_OUT=()
        if [[ $SC_KIND == pix ]]; then
            ui_pix_block "$SC_PIX" "$SC_W"
            BG_OUT=("${PIX_ROWS[@]}"); CELLS=("${PIX_CELLS[@]}")
        else
            mapfile -t bgt <<< "$SC_BG_TXT"
            mapfile -t bgc <<< "$SC_BG_COL"
            for (( i = 0; i < SC_H; i++ )); do
                printf -v row '%-*s' "$SC_W" "${bgt[i]}"
                printf -v col '%-*s' "$SC_W" "${bgc[i]}"
                BGT[i]=$row; BGC[i]=$col
                ui_paint "$row" "$col"
                BG_OUT[i]=$REPLY
            done
        fi
        for src in "${SC_SOURCES[@]}"; do               # smoke and bubble sources
            read -r row col drift hcfg kind <<< "$src"
            SRC_R[NSRC]=$(( ART_TOP + row )); SRC_C[NSRC]=$(( ART_X + 1 + col ))
            SRC_DRIFT[NSRC]=$drift; SRC_KIND[NSRC]=$kind
            avail=$(( SRC_R[NSRC] - 1 ))                # rows above the source, up to the top of the screen
            (( avail > SMOKE_MAXH )) && avail=$SMOKE_MAXH
            (( hcfg < avail )) && avail=$hcfg
            SRC_H[NSRC]=$avail
            case $kind in
                bubble) SRC_K[NSRC]=2 ;;
                spark)  SRC_K[NSRC]=4 ;;
                gsmoke) SRC_K[NSRC]=$(( avail > 4 ? avail : 4 )) ;;
                pipe)   SRC_K[NSRC]=$(( avail > 3 ? avail : 3 )) ;;
                *)      SRC_K[NSRC]=$(( avail * 3 / 2 > 4 ? avail * 3 / 2 : 4 )) ;;
            esac
            NSRC=$(( NSRC + 1 ))
        done
        local title=" linux_apps_setup_wizard v$VERSION " dashes
        printf -v dashes '%*s' $(( (C - ${#title}) / 2 )) ''
        dashes=${dashes// /-}
        SEP_LINE=$'\e[90m'$dashes$'\e[97m'$title$'\e[90m'$dashes$'\e[0m'
        if (( C < 40 )); then ui_header_line $(( C - 1 )); SEP_LINE=$REPLY; fi    # a narrow screen (phone): the title is shortened to fit
    fi
    if [[ $LAYOUT == side ]]; then ui_header_line "$LP_W"; HEADER_LINE=$REPLY; fi
}

# What is on screen at (row, col) without any smoke on it  ->  REPLY
ui_bg_cell() {
    local sr=$(( $1 - ART_TOP )) sc=$(( $2 - ART_X - 1 )) ch c
    REPLY=" "
    if [[ $SCENE != none ]] && (( sr >= 0 && sr < SC_H && sc >= 0 && sc < SC_W )); then
        if [[ $SC_KIND == pix ]]; then
            REPLY=${CELLS[sr * SC_W + sc]}                 # pixel art: the copy that is kept up to date
        else
            ch=${BGT[sr]:sc:1}
            if [[ -n $ch && $ch != " " ]]; then
                c=${BGC[sr]:sc:1}
                REPLY=${SGR[${c:-.}]}$ch$'\e[0m'
            fi
        fi
    fi
}

# Everything we draw goes out in small self-contained pieces: save cursor ... draw ... restore cursor
UI_BUF=""
ui_begin() { UI_BUF=$'\e7\e[0m'; }
ui_add()   {
    if (( ${#UI_BUF} + ${#1} > 700 && ${#UI_BUF} > 6 )); then printf '%s\e8' "$UI_BUF" >&4; UI_BUF=$'\e7\e[0m'; fi
    UI_BUF+=$1
}
ui_end()   { printf '%s\e8' "$UI_BUF" >&4; UI_BUF=""; }

# The progress bar on the last line
UI_LAST_BAR=""
ui_draw_bar() {
    local done=$BAR_DONE total=$BAR_TOTAL label=$BAR_LABEL pct bw fill i left="" right mid avail line el
    if IFS='|' read -r done total label 2> /dev/null < "$UI_DIR/state" && [[ -n $total ]]; then
        BAR_DONE=$done; BAR_TOTAL=$total; BAR_LABEL=$label
    else
        done=$BAR_DONE; total=$BAR_TOTAL; label=$BAR_LABEL
    fi
    (( total > 0 )) && pct=$(( done * 100 / total )) || pct=0
    (( pct > 100 )) && pct=100
    bw=$(( C / 3 )); (( bw < 10 )) && bw=10; (( bw > 40 )) && bw=40
    fill=$(( pct * bw / 100 ))
    el=$(( SECONDS - UI_START ))
    printf -v right ' %02d:%02d ' $(( el / 60 )) $(( el % 60 ))
    printf -v left ' %3d%% [' "$pct"
    mid="] $done/$total  "
    avail=$(( C - 1 - ${#left} - bw - ${#mid} - ${#right} ))
    (( avail < 0 )) && avail=0
    label=${label:0:avail}
    printf -v line '%-*s' "$avail" "$label"
    local filled="" empty=""
    for (( i = 0; i < bw; i++ )); do
        if (( i < fill )); then filled+="#"; else empty+="-"; fi
    done
    line=$'\e[1;97m'$left$'\e[0m\e[92m'$filled$'\e[90m'$empty$'\e[0m\e[37m'$mid$'\e[93m'$line$'\e[96m'$right$'\e[0m'
    if [[ $line != "$UI_LAST_BAR" || $1 == force ]]; then
        UI_LAST_BAR=$line
        printf '\e7\e[%d;1H%s\e8' "$L" "$line" >&4
    fi
}

# Draw the parts that do not move: the scene, the separator, the bar, and set the scroll region
ui_draw_static() {
    [[ $LAYOUT == side ]] && { ui_draw_static_side "$1"; return; }
    local i
    printf '\e[0m\e[r\e[2J\e[?25l' >&4
    if [[ $SCENE != none ]]; then
        ui_begin
        for (( i = 0; i < SC_H; i++ )); do
            ui_add "${ESC}[$(( ART_TOP + i ));$(( ART_X + 1 ))H${BG_OUT[i]}"
        done
        ui_add "${ESC}[${ANIM_ROWS};1H${SEP_LINE}"
        ui_end
    fi
    ui_draw_bar force
    printf '\e[%d;%dr\e[%d;1H' "$REGION_TOP" "$REGION_BOT" "$REGION_TOP" >&4   # output scrolls in here
}

# Side by side: title, divider, the picture, the progress bar. "full" clears the whole screen first (only at the start; when
# the window is resized the output panel and this process each redraw their own part, so nothing is cleared that the other
# one has just drawn).
ui_draw_static_side() {
    local mode=$1 i row
    [[ $mode == full ]] && printf '\e[0m\e[r\e[2J\e[?25l' >&4
    ui_begin
    ui_add "${ESC}[1;1H${HEADER_LINE}"
    if [[ $SCENE != none ]]; then
        printf -v row '%*s' "$RP_W" ''
        for (( i = 1; i < L; i++ )); do                 # the divider, and a clean right half for the picture
            ui_add "${ESC}[${i};$(( LP_W + 1 ))H${ESC}[90m│${ESC}[0m${row}"
        done
        for (( i = 0; i < SC_H; i++ )); do
            ui_add "${ESC}[$(( ART_TOP + i ));$(( ART_X + 1 ))H${BG_OUT[i]}"
        done
    fi
    ui_end
    ui_draw_bar force
    printf '\e[1;1H' >&4      # the real cursor waits in the corner: a stray prompt (sudo) lands there and can never scroll the screen
}

# Draw one character of smoke / spark at (row, col) and remember it, so the next frame can erase it
#   ui_plot <row> <col> <glyph> <colour code>
ui_plot() {
    (( $1 < AREA_R0 || $1 > AREA_R1 || $2 < AREA_C0 || $2 > AREA_C1 )) && return
    PREV_R[NPREV]=$1; PREV_C[NPREV]=$2; NPREV=$(( NPREV + 1 ))
    ui_add "${ESC}[${1};${2}H${4}${3}${ESC}[0m"
}

# One animation frame
ui_tick() {
    local t=$1 i f idx r s k K life age h sway dx frac ch c hmax rr cc sgr src dst
    [[ $SCENE == none ]] && return
    # 1. take last frame's smoke away (put back what was underneath)
    if (( NPREV > 0 )); then
        ui_begin
        for (( i = 0; i < NPREV; i++ )); do
            ui_bg_cell "${PREV_R[i]}" "${PREV_C[i]}"
            ui_add "${ESC}[${PREV_R[i]};${PREV_C[i]}H${REPLY}"
        done
        ui_end
        NPREV=0
    fi
    # 2. redraw the pieces whose picture changed (stirring, flames, glowing pipe)
    for (( idx = 0; idx < NSPR; idx++ )); do
        if [[ ${SPR_MODE[idx]} == rand ]]; then
            f=${SPR_LAST[idx]}
            if (( f < 0 || t % SPR_PER[idx] == 0 )); then
                f=$(( RANDOM % SPR_N[idx] ))
                (( f == SPR_LAST[idx] )) && f=$(( (f + 1) % SPR_N[idx] ))
            fi
        else
            f=$(( t / SPR_PER[idx] % SPR_N[idx] ))
        fi
        if (( f != SPR_LAST[idx] )); then
            SPR_LAST[idx]=$f
            ui_begin
            for (( r = 0; r < SPR_H[idx]; r++ )); do
                ui_add "${ESC}[$(( ART_TOP + SPR_R[idx] + r ));$(( ART_X + 1 + SPR_C[idx] ))H${SPR_OUT[SPR_OFF[idx] + f * SPR_H[idx] + r]}"
            done
            ui_end
            if (( SPR_PIX[idx] && SPR_SYNC[idx] )); then   # keep the "what is on screen" copy up to date
                for (( r = 0; r < SPR_H[idx]; r++ )); do
                    dst=$(( (SPR_R[idx] + r) * SC_W + SPR_C[idx] ))
                    src=$(( SPR_COFF[idx] + (f * SPR_H[idx] + r) * SPR_W[idx] ))
                    for (( c = 0; c < SPR_W[idx]; c++ )); do CELLS[dst + c]=${SPR_CELL[src + c]}; done
                done
            fi
        fi
    done
    # 3. smoke rises from the cauldron and the pipe, bubbles pop at the rim
    ui_begin
    for (( s = 0; s < NSRC; s++ )); do
        hmax=${SRC_H[s]}; K=${SRC_K[s]}
        (( hmax < 1 )) && continue
        case ${SRC_KIND[s]} in bubble) life=6 ;; spark) life=8 ;; *) life=$(( hmax * 3 )) ;; esac
        for (( k = 0; k < K; k++ )); do
            age=$(( (t + k * life / K + s * 5) % life ))
            h=$(( age * hmax / life ))
            sway=${WOBBLE[(age / 2 + k * 3 + s * 4) % 16]}
            frac=$(( age * 100 / life ))
            case ${SRC_KIND[s]} in
                bubble)
                    dx=$(( (RANDOM % 7) - 3 ))
                    case $(( age % 3 )) in 0) ch=o; c=L ;; 1) ch=O; c=L ;; *) ch=.; c=G ;; esac
                    sgr=${SGR[$c]} ;;
                gsmoke)                                     # green magic smoke: dense and bright, then thin and dark
                    dx=$(( sway * (h + 3) / 4 + SRC_DRIFT[s] * h / 2 ))
                    ch=${SMOKE_GLYPHS[frac * 4 / 100]}
                    sgr="${ESC}[38;5;${GREEN_SMOKE[frac * 7 / 100]}m" ;;
                spark)                                      # glowing sparks
                    dx=$(( ((k * 7 + age * 3) % 9) - 4 ))
                    ch=${SPARK_GLYPHS[frac * 3 / 100]}
                    sgr="${ESC}[38;5;${SPARK_COLORS[frac * 3 / 100]}m" ;;
                *)
                    dx=$(( sway * (h + 3) / 4 + SRC_DRIFT[s] * h / 2 ))
                    if (( frac < 70 )); then ch=${PAREN:(k + age / 3) % 2:1}; else ch=${DOT:k % 2:1}; fi
                    if (( frac < 35 )); then c=w; elif (( frac < 70 )); then c=g; else c=d; fi
                    sgr=${SGR[$c]} ;;
            esac
            rr=$(( SRC_R[s] - h )); cc=$(( SRC_C[s] + dx ))
            if [[ ${SRC_KIND[s]} == gsmoke ]]; then         # a puff: wide and dense when fresh, small and thin when old
                if   (( frac < 30 )); then ui_plot "$rr" $(( cc - 1 )) "▒" "$sgr"; ui_plot "$rr" "$cc" "▓" "$sgr"; ui_plot "$rr" $(( cc + 1 )) "▒" "$sgr"
                elif (( frac < 60 )); then ui_plot "$rr" "$cc" "▒" "$sgr"; ui_plot "$rr" $(( cc + 1 )) "░" "$sgr"
                else ui_plot "$rr" "$cc" "$ch" "$sgr"
                fi
            else
                ui_plot "$rr" "$cc" "$ch" "$sgr"
            fi
        done
    done
    ui_end
}
PAREN="()"
DOT=".'"

# ---- the output panel of the side-by-side layout ----
# A terminal can only scroll whole rows, never just the left columns. So in this layout everything the commands print
# comes through a pipe to THIS process: it saves it in the log, cuts it into lines, wraps them to the panel width and
# draws them itself. (In the stacked layout the terminal scrolls the output and "tee" only copies it to the log.)

# Keep the text and the colours of a line, drop every other control sequence and control character, turn tabs into spaces  ->  REPLY
ui_panel_clean() {
    local s=$1 out="" pre n vis=0 spaces seq
    local re_csi=$'^\e\\[[0-?]*[ -/]*[@-~]' re_sgr=$'^\e\\[[0-9;]*m$' re_cut=$'^\e\\[[0-?]*[ -/]*$'
    local re_osc=$'^\e\\][^\a\e]*(\a|\e\\\\)' re_cs=$'^\e[()*+][0-9A-Za-z]'
    case $s in
        *[[:cntrl:]]*) ;;
        *) REPLY=$s; return ;;                          # plain text: nothing to do
    esac
    while [[ -n $s ]]; do
        pre=${s%%[[:cntrl:]]*}                          # the text up to the next control character
        if [[ -n $pre ]]; then out+=$pre; vis=$(( vis + ${#pre} )); s=${s:${#pre}}; continue; fi
        case ${s:0:1} in
            $'\e')
                if [[ $s =~ $re_csi ]]; then
                    seq=${BASH_REMATCH[0]}
                    [[ $seq =~ $re_sgr ]] && out+=$seq  # colours stay, cursor movement and the like goes
                    s=${s:${#seq}}
                elif [[ $s =~ $re_osc || $s =~ $re_cs ]]; then
                    s=${s:${#BASH_REMATCH[0]}}
                elif [[ $s =~ $re_cut ]]; then
                    s=""                                # a sequence that is cut off: the rest of it comes with the next text
                else
                    s=${s:2}                            # ESC plus one character (save cursor, keypad mode, ...)
                fi ;;
            $'\t')
                n=$(( 8 - vis % 8 )); printf -v spaces '%*s' "$n" ''
                out+=$spaces; vis=$(( vis + n )); s=${s:1} ;;
            *) s=${s:1} ;;                              # any other control character (bell, backspace, ...): dropped
        esac
    done
    REPLY=$out
}

# Cut a line (text and colours only) into rows of at most PW characters  ->  appended to the two arrays named in $1 and $2
ui_panel_wrap_into() {
    local -n _rows=$1 _lens=$2
    local line=$3 w=$PW rest cur="" curlen=0 active="" text code hascode space
    local re=$'^([^\e]*)\e\\[([0-9;]*)m'
    (( w < 1 )) && w=1
    if [[ $line != *$'\e'* ]]; then                     # plain text (the usual case)
        while (( ${#line} > w )); do _rows+=("${line:0:w}"); _lens+=("$w"); line=${line:w}; done
        _rows+=("$line"); _lens+=("${#line}")
        return
    fi
    rest=$line
    while [[ -n $rest ]]; do
        if [[ $rest =~ $re ]]; then
            text=${BASH_REMATCH[1]}; code=${BASH_REMATCH[2]}; hascode=1
            rest=${rest:${#BASH_REMATCH[0]}}
        else
            text=$rest; code=""; hascode=0; rest=""
        fi
        while [[ -n $text ]]; do
            space=$(( w - curlen ))
            if (( space <= 0 )); then                   # the row is full: start the next one with the colour still on
                _rows+=("$cur"$'\e[0m'); _lens+=("$curlen"); cur=$active; curlen=0; space=$w
            fi
            if (( ${#text} <= space )); then
                cur+=$text; curlen=$(( curlen + ${#text} )); text=""
            else
                cur+=${text:0:space}; curlen=$(( curlen + space )); text=${text:space}
            fi
        done
        if (( hascode )); then
            cur+=$'\e['$code'm'
            if [[ -z $code || $code == 0 || $code == 00 ]]; then active=""
            elif [[ $code == 0\;* ]]; then active=$'\e['${code#0;}'m'
            else active+=$'\e['$code'm'; fi
        fi
    done
    _rows+=("$cur"$'\e[0m'); _lens+=("$curlen")
}

# Add a finished line to the history and to the wrapped rows
ui_panel_wrap() {
    ui_panel_wrap_into ROWS ROWLEN "$1"
    if (( ${#ROWS[@]} > 800 )); then ROWS=("${ROWS[@]:300}"); ROWLEN=("${ROWLEN[@]:300}"); fi
}
ui_panel_line() {
    local line=$1
    while [[ $line == *$'\r' ]]; do line=${line%$'\r'}; done   # CRLF line ends
    [[ $line == *$'\r'* ]] && line=${line##*$'\r'}      # progress output rewrites its line: the last version counts
    ui_panel_clean "$line"
    HIST+=("$REPLY")
    if (( ${#HIST[@]} > 1500 )); then HIST=("${HIST[@]:500}"); fi
    ui_panel_wrap "$REPLY"
}

# New text from the commands: finished lines go to the history, an unfinished one (a prompt, a progress bar) is shown live
ui_panel_feed() {
    local data="$PARTIAL$1" line
    while [[ $data == *$'\n'* ]]; do
        line=${data%%$'\n'*}
        data=${data#*$'\n'}
        ui_panel_line "$line"
    done
    if (( ${#data} > 4000 )); then ui_panel_line "$data"; data=""; fi    # a line that never ends: show what there is
    PARTIAL=$data
    DIRTY=1
}

# Draw the last PH rows (only the rows that changed since the last time)
ui_panel_draw() {
    local -a prow=() plen=()
    local nr=${#ROWS[@]} np total first i r txt len pad out part
    DIRTY=0
    if [[ -n $PARTIAL ]]; then
        part=$PARTIAL
        while [[ $part == *$'\r' ]]; do part=${part%$'\r'}; done       # progress output: show its newest version
        part=${part##*$'\r'}
        ui_panel_clean "$part"; ui_panel_wrap_into prow plen "$REPLY"
    fi
    np=${#prow[@]}; total=$(( nr + np ))
    first=$(( total > PH ? total - PH : 0 ))
    ui_begin
    for (( i = 0; i < PH; i++ )); do
        r=$(( first + i ))
        if   (( r < nr ));    then txt=${ROWS[r]};          len=${ROWLEN[r]}
        elif (( r < total )); then txt=${prow[r - nr]};     len=${plen[r - nr]}
        else                       txt="";                  len=0; fi
        pad=$(( PW - len )); (( pad < 0 )) && pad=0
        printf -v out '%s\e[0m%*s' "$txt" "$pad" ''
        if [[ $out != "${SHOWN[i]}" ]]; then
            SHOWN[i]=$out
            ui_add "${ESC}[$(( PROW + i ));${PCOL}H${out}"
        fi
    done
    ui_end
}

# Follow the layout the animation process publishes (it changes when the window is resized)
# (No "read" here on purpose: after a "read -t" has timed out in the middle of a chunk, bash keeps the rest of that
# chunk in an internal buffer, and the next "read" or "mapfile" - whatever file it is told to read - would swallow it.)
ui_panel_relayout() {
    local lay line g c r w h
    local re='^([0-9]+) ([0-9]+) ([0-9]+) ([0-9]+) ([0-9]+) \.$'
    lay=$(< "$UI_DIR/layout") 2> /dev/null || return 0
    [[ $lay =~ $re ]] || return 0
    g=${BASH_REMATCH[1]}; c=${BASH_REMATCH[2]}; r=${BASH_REMATCH[3]}; w=${BASH_REMATCH[4]}; h=${BASH_REMATCH[5]}
    [[ $g != "$LGEN" ]] || return 0
    LGEN=$g; PCOL=$c; PROW=$r; PW=$w; PH=$h
    ROWS=(); ROWLEN=(); SHOWN=()
    for line in "${HIST[@]}"; do ui_panel_wrap "$line"; done
    DIRTY=1
}

# The process itself: reads what the commands print (stdin), until every writer has closed the pipe.
# If the main script is killed hard, its children may still be printing: they must not get a broken pipe (that could stop
# an installer half way), so the process keeps reading and passes the text on to the terminal like "tee" does.
ui_panel_proc() {
    local chunk rc now last_draw=0 LGEN=0 PCOL=1 PROW=2 PW=40 PH=20 PARTIAL="" DIRTY=1 GONE=0
    local -a HIST=() ROWS=() ROWLEN=() SHOWN=()
    trap '' INT                                         # Ctrl+C is handled by the main script
    exec 5>> "$OUTPUT_LOG"                              # the log gets everything, exactly as printed
    ui_panel_relayout
    while :; do
        chunk=""
        IFS= read -r -N 4096 -t "$PANEL_POLL" chunk; rc=$?
        (( GONE )) || kill -0 "$$" 2> /dev/null || GONE=1     # $$ is the main script, also in this subshell
        if [[ -n $chunk ]]; then
            printf '%s' "$chunk" >&5
            if (( GONE )); then printf '%s' "$chunk" >&4; else ui_panel_feed "$chunk"; fi
        fi
        if (( ! GONE )); then
            ui_panel_relayout
            if (( DIRTY )); then
                now=${EPOCHREALTIME/./}
                if (( rc != 0 || now - last_draw >= 40000 )); then ui_panel_draw; last_draw=$now; fi   # at most ~25 redraws a second
            fi
        fi
        (( rc == 1 )) && break                          # end of input
    done
    (( GONE )) || ui_panel_draw
}

# Put the terminal back the way it was
ui_restore_terminal() {
    printf '\e[0m\e[r\e[?25h\e[%d;1H\n' "$L" >&4
}

# When the script ends the cauldron settles: the still picture again, without the smoke (side-by-side layout)
ui_final_frame() {
    [[ $LAYOUT == side && $SCENE != none ]] && ui_draw_static_side resize
}

# Runs in the background: draws a frame every TICK seconds until the main script is gone
ui_animator() {
    local parent=$1 t=0 size
    trap '' INT                    # Ctrl+C is handled by the main script
    trap 'ui_final_frame; exit 0' TERM
    ui_tick 0
    while kill -0 "$parent" 2> /dev/null; do
        sleep "$TICK"
        t=$(( t + 1 ))
        ui_tick "$t"
        ui_draw_bar
        if (( t % 8 == 0 )); then                      # window resized? lay everything out again
            size=$(stty size <&4 2> /dev/null)
            if [[ -n $size && $size != "$L $C" ]]; then
                L=${size% *}; C=${size#* }
                ui_layout; ui_load_scene
                if [[ $LAYOUT == side ]]; then
                    LAYOUT_GEN=$(( LAYOUT_GEN + 1 )); ui_publish_layout
                    sleep 0.3                              # let the output panel move first
                    ui_draw_static resize
                else
                    ui_draw_static full
                fi
                ui_tick "$t"
            fi
        fi
    done
    ui_final_frame
    ui_restore_terminal            # the main script died without cleaning up
}

# Tell the animation which task is running.  ui_set_state <tasks done> <label>
ui_set_state() {
    (( UI_ACTIVE )) || return 0
    printf '%s|%s|%s\n' "$1" "$TOTAL_TASKS" "$2" > "$UI_DIR/state"
}

# Marks the start of the next task for the progress bar:  next_task "Name"
next_task() {
    TASK_NUM=$(( TASK_NUM + 1 ))
    ui_set_state $(( TASK_NUM - 1 )) "$1"
}

# Everything done: bar to 100%
ui_finish() {
    if (( ${#FAILED_STEPS[@]} > 0 )); then
        ui_set_state "$TOTAL_TASKS" "Finished, ${#FAILED_STEPS[@]} step(s) failed"
    else
        ui_set_state "$TOTAL_TASKS" "Finished"
    fi
}

# Turn the animated screen on (does nothing when it cannot or should not run)
ui_start() {
    [[ -z $NO_ANIMATION ]] || return 0
    [[ -t 1 && -n $TERM && $TERM != dumb ]] || return 0
    exec 4>&1
    local size
    size=$(stty size <&4 2> /dev/null)
    L=${size% *}; C=${size#* }
    if [[ -z $size ]] || (( L < 12 || C < 30 )); then exec 4>&-; return 0; fi
    UI_DIR=$(mktemp -d) || { exec 4>&-; return 0; }
    BAR_DONE=0; BAR_TOTAL=$TOTAL_TASKS; BAR_LABEL="Starting..."
    UI_START=$SECONDS
    touch "$OUTPUT_LOG" 2> /dev/null || OUTPUT_LOG=/dev/null
    printf '\n---- %s  linux_apps_setup_wizard v%s ----\n' "$(date '+%F %T')" "$VERSION" >> "$OUTPUT_LOG"
    APT_ENV=(env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none)   # no full-screen dialogs
    APT_FLAGS=(-o APT::Cmd::Disable-Script-Warning=true -o Dpkg::Progress-Fancy=0
               -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)   # a changed config file: keep the current one
    LAYOUT=stacked
    if [[ -z $STACKED_ONLY ]] && ui_side_fits; then LAYOUT=side; fi
    ui_layout
    ui_load_scene
    printf '%s|%s|%s\n' 0 "$TOTAL_TASKS" "Starting..." > "$UI_DIR/state"
    LAYOUT_GEN=1
    [[ $LAYOUT == side ]] && ui_publish_layout
    UI_ACTIVE=1
    ui_draw_static full
    if [[ $LAYOUT == side ]]; then
        exec > >(ui_panel_proc 2> /dev/null) 2>&1      # a process that draws the output on the left of the screen (and logs it)
    else
        exec > >(tee -ia "$OUTPUT_LOG" >&4) 2>&1       # everything printed goes to the screen AND the log
    fi
    TEE_PID=$!
    ui_animator "$$" > /dev/null 2>&1 &
    ANIM_PID=$!
}

# Turn it off again (also runs when the script exits for any reason)
ui_stop() {
    local size i
    (( UI_ACTIVE )) || return 0
    UI_ACTIVE=0
    kill "$ANIM_PID" 2> /dev/null
    wait "$ANIM_PID" 2> /dev/null
    size=$(stty size <&4 2> /dev/null)                 # the window may have been resized
    [[ -n $size ]] && { L=${size% *}; C=${size#* }; }
    ui_draw_bar force                                  # last look at the progress bar
    exec >&4 2>&4                                      # stop using the pipe so the log process can finish
    for (( i = 0; i < 30; i++ )); do
        kill -0 "$TEE_PID" 2> /dev/null || break
        sleep 0.1
    done
    kill "$TEE_PID" 2> /dev/null
    ui_restore_terminal
    rm -rf "$UI_DIR"
    exec 4>&-
}

# ---- the scenes: pixel art for UTF-8 + 256 colour terminals (38+ lines: big, 30+ lines: compact),
# ---- or ASCII art: small (24+ lines) and large (38+ lines) ----
# art = the picture, colour map = one letter per character (see SGR above), sprites = the moving parts
scene_small() {
    SC_W=54 SC_H=11
    SC_BG_TXT=$(cat <<'EOF'
                          /\
                         /  \
                        /    \
                    ___/______\___
                       ( o  o )
                   ====(  /\  )===
         .-""""""""""\\\\||||////"        """-.
        (             \\\||||///             )
         `-.____________\\||//______________.-'


EOF
)
    SC_BG_COL=$(cat <<'EOF'
..........................dd
.........................d..d
........................d....d
....................ggggddddddgggg
.......................Y.w..w.Y
...................yyyyY..YY..Yggg
.........dgggggggggggwwwwwwwwwwwwg........gggd 
........d.............wwwwwwwwww.............d
.........dddddddddddddddwwwwwwdddddddddddddddd 


EOF
)
    # paddle + hand: swings like a pendulum
    ui_add_sprite 2 34 2 seq "$(cat <<'EOF'
       /
      / 
     /  
====@   
"""/""""
--
     /  
    /   
    /   
====@   
"""/""""
--
   |    
   |    
   |    
===@    
"""|""""
--
 \      
  \     
  \     
==@     
"""\""""
--
   |    
   |    
   |    
===@    
"""|""""
--
     /  
    /   
    /   
====@   
"""/""""
EOF
)" '=g@Y/y\y|y"g'
    # flames under the cauldron
    ui_add_sprite 9 10 1 rand "$(cat <<'EOF'
     )  (   ) (   )  (   ) (  )     
   ( ) )( ( ) )( ( ) )( ( ) )( (   
--
    (  ) (  )  ) (  )  ( )  (  )    
   ) ( ( )) ( ) )( ( ( ) )( ) )(   
--
     (  )  ) (  (  )  )  (  ) (     
   ( ) )( ) ( ( ) )( ( ) )( ( ) )   
--
    ) (  )(  ) (  ) (  )(  ) (  (   
   ( )( ) )( ( ) ( )( ( ) )( )( )   
EOF
)" 'rows:YR'
    # glowing pipe bowl
    ui_add_sprite 5 16 3 seq "$(cat <<'EOF'
(_)
--
(*)
--
(_)
--
(.)
EOF
)" '(y)y_R*R.R'
    # smoke / bubble sources: scene-row scene-col drift height kind
    SC_SOURCES=("5 11 -1 99 plume" "5 46 1 99 plume" "4 17 -1 99 pipe")
}

scene_large() {
    SC_W=72 SC_H=18
    SC_BG_TXT=$(cat <<'EOF'
   .                               /\       .               +
            *               .     /  \
  ,--.                           /    \                              *
 (    )                         /      \
  `-|'                         /        \                         .
    |   .                     /__________\
    |                    _.--'------------'--._
    |                       ( \  o    o  / )
    |                       (      /\      )
    |                 =======\   ,====,   /=====
    |      .-""""""""""""""\\\\\\||||||||///////         """-.
    |     /                 \\\\\||||||||///////               \
    |     (                  \\\\|||||||||//////               )
    |      \                   \\\||||||||/////               /
    |       `-.__________________\\||||||////________________.-'
    |


EOF
)
    SC_BG_COL=$(cat <<'EOF'
...d...............................dd.......d...............d
............d...............d.....d..d
..yyyy...........................d....d..............................d
.y....y.........................d......d
..yyyy.........................d........d.........................d
....y...d.....................dggggggggggd
....y....................gggggddddddddddddggggg
....y.......................Y.w..Y....Y..Y.w
....y.......................Y......YY......Y
....y.................yyyyyyyY...Ywwwww...Yggggg
....y......dgggggggggggggggwwwwwwwwwwwwwwwwwwwww.........ggggg
....y.....d.................wwwwwwwwwwwwwwwwwwww...............d
....y.....d..................wwwwwwwwwwwwwwwwwww...............d
....y......d...................wwwwwwwwwwwwwwww...............d
....y.......dddddddddddddddddddddwwwwwwwwwwwwddddddddddddddddd  
....y


EOF
)
    # paddle + hand: swings like a pendulum
    ui_add_sprite 4 48 2 seq "$(cat <<'EOF'
       / 
       / 
      /  
      /  
     /   
=====@   
""""/""""
--
      /  
      /  
     /   
     /   
     /   
====@    
""""/""""
--
    |    
    |    
    |    
    |    
    |    
====@    
""""|""""
--
  \      
  \      
   \     
   \     
   \     
====@    
""""\""""
--
    |    
    |    
    |    
    |    
    |    
====@    
""""|""""
--
      /  
      /  
     /   
     /   
     /   
====@    
""""/""""
EOF
)" '=g@Y/y\y|y"g'
    # flames under the cauldron
    ui_add_sprite 15 10 1 rand "$(cat <<'EOF'
      )   (    )  (    )   (   )  (    )   (        
    ( )  ) (  ( ) )  ( ( )  ) ( (  ) )  ( )  (      
   ) ( ) ( ) )( ( ( ) )( ) ( ( ) )( ) ( ) ( ( )     
--
     (    )   (   )   (    )   (   )   (    )       
    ) (  ( ) )  ( ) ) (  ( ) )  ( ) ) (  ( )  )     
   ( ) ( ) ( ( ) )( ) ( ) )( ( ) ( )( ) ) ( ) )(    
--
       )  (   )   (   )  (    )   (   )  (          
    ( ) )  ( ( )  ) (  ( ) )  ( (  ) ) (  ( ) )     
   ) ( )( ) ( ) ( ( )( ) ( ( ) )( ) ( )( ) ) ( (    
--
      (   )    (  )   (    )  (   )   (    )        
    ) ( ) (  ) ( ( ) (  ) ) ( ( ) )  ( ) (  ) ( )   
   ( )( ) ( )( ) ) ( ( ) )( ) ( ) )( ( ) ( ) )( ) ( 
EOF
)" 'rows:YyR'
    # glowing pipe bowl
    ui_add_sprite 9 19 3 seq "$(cat <<'EOF'
(_)
--
(*)
--
(_)
--
(.)
EOF
)" '(y)y_R*R.R'
    # smoke sources: scene-row scene-col drift height kind
    SC_SOURCES=("9 13 -1 99 plume" "9 59 1 99 plume" "8 20 -1 99 pipe")
}

scene_pixlarge() {
    SC_KIND=pix SC_W=72 SC_H=18
    # the picture: 2 rows of the text below = 1 row of the terminal; letters are colours (see PIXPAL), . = nothing
    SC_PIX=$(cat <<'EOF'
....nnnn...................L............................................
...njffjn............LLLLLLFL...........................................
..njf..njn..........LFFFFLFFFLL.........................................
..nf....nf........LLFFFFFLCCCFC.........................................
..njnjmnjf.......LFFFFFFFFFC.LFL........................................
...njnnjf........LFFFFFFFFFFLLCC........................................
....nfff........LFFFFFFFFFFFC...........................................
....jm..........LFFFFFFFFFFFC...........................................
....jm..........LFFFFFFFFFFFC...........................................
....jm.........LAAAAAAAAAAAACL......njnxxxx.............................
....jm.g...LLCCnnnnnnnnnnnnnnGCCLL..njnrrrr.............................
.....jm......LLGGGGGGGGGGGGGGGLL..LLnjnrrrrrg...........................
.....jm........LLLLLLLLLLLLLLL...LEEnjnrrrrrmg..........................
.....jm........KNNNNNSorrrQQQQ..LEEEnjnrrorrmjRRRRRRRRRRR...............
.....jm.......KNNNNNNSorrrrArrrkrEEEnjnooorgjmgcccccccccccRRRRRR........
....gjm.......KNNNNNNNoorrrrrrroEEEEBBdddkkgjjmgeeheeeddddccccccRR......
.....jm.......KNNNNNNNOorTTTTTTEEEEBddeeeekkgjmjlllleeeeededdddcccRR....
....jm.g......KNNNNNNNOorrrrxSTEEEBddddddleeegjmgeeeeedddedddddcccIIPPP.
....jm........KNNNNNNOSSSSSSSSSTEBccpdeddddddhjjjhddddddddccccccII.PJFJP
..u.jm......CEKNNNNNNOSSMSSSSSpTBIIIIcccccccccljlcccccccccIIIIIIDDLPF.PF
..y.jm....CEEKEKNNNNNOSSSSSSMSSTDHDFDDRIIIIIIIIeIIIIIIIIIDDDDDDDDDPF...P
..zzgm....CEEKEKNNNNNNOMSSMSSSpFDHFHDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEPF...P
..zs.mrrrCCEEKEKNNNNNSOSSSSSSSTDDHFDDDDDDDDDEDDEDDDEDDDDDEDDDDDDDDPF...P
..zz.jrrrCCEKEEKNNNNNSOSSSSMSSTHDHEDDDDDDDDDDDEDDDDDDDDEDEDDDDDDDDPF...P
..zs.jrorCEEKEEGKNNNNSOSSMSSSpTDDDDDEDEDDDEDDDDDDDDDDDDDDDDDEDDDDDIPP.PF
..zz.jm.CCEEKEEGEKNNNSEOSSSSSTDEDEEDDDDDDDDDDDDDDEDDDDDDDDDDDDDDDDIPJPJF
..zz.jm.CEEEECGEEKNSEEEOMSSSSTjDDDDDDDDDEDDDDDEDDEDDDqDDDDDDDDEDDI..PFu.
..zz.jmCEGEEGCEEGGSEEEECOSSST.LIDDDEEDDDDDDDDDDDDDEDtqDDDDDDDDDII.....y.
.bbbbbbbbbEEECEGEECEEEECOSMST...LIDDDDfqDDEDDjDDDmfDvtDDDDDjDIq.......zz
.bnnnnnnnbEGECEEEECEGEGCEOSTK.....LIIDvqDDmqmjjjjjjtyvqDEDqII.vq......zz
.bbbbbbbbbEEECEEEECEEEECEOSTjy..yq..mmyvqmyqjgggyqgvyvvjjjqyjqyv......zs
.aaaaaaaaaEEECGEEECEEEECEETmEmyjyymmjvyyvjyyqgggyygvyyvgggqyyvyyvjjj..zz
iiiiiiiiiiiEECGEEECEEEECEETEmKyyyyvjtyyyvyyyvffyyyvyyyvgggyyyyyyvggf..zz
ixxxxxxxxxiEECEEEECEEEECEEEmEmvvvvvjvvvvvvvvv.vvvvvvvvvtfvvvvvvvvtgf..zs
iiiiiiiiiiiIIIIIIIIIIIIIIImImImtttttttttttttttttttttttttttttttttttjjjfzz
fffffffffffIIIIIIIIIIIIIIIIIIIIqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqffffzz
EOF
)
    # paddle swirling in the glowing pot
    ui_add_psprite 4 28 2 seq "$(cat <<'EOF'
C.....................................
CL......njnxxxx.......................
nGCCLL..njnrrrr.......................
GGLL..LLnjnrrrrrg.....................
LL...LEEnjnrrrrrmg....................
QQ..LEEEnjnrrorrmjRRRRRRRRRRR.........
rrrkrEEEnjnooorgjmgcccccccccccRRRRRR..
rrroEEEEBBdddkkgjjmgeeheeeddddccccccRR
TTTEEEEBddeeeekkgjmjlllleeeeededdddccc
xSTEEEBddddddleeegjmgeeeeedddedddddccc
SSSTEBccpdeddddddhjjjhddddddddccccccII
SSpTBIIIIcccccccccljlcccccccccIIIIIIDD
MSSTDHDFDDRIIIIIIIIeIIIIIIIIIDDDDDDDDD
SSpFDHFHDDDDDDDDDDDDDDDDDDDDDDDDDDDDDE
--
C.....................................
CL......njnxxxx.......................
nGCCLL..njnrrrr.......................
GGLL..LLnjnrrrrrg.....................
LL...LEEnjnrrrrrmg....................
QQ..LEEEnjnrrorrjmgRRRRRRRRRR.........
rrrkrEEEnjnooorgjjmmccccccccccRRRRRR..
rrroEEEEBBdddkkegjjjmgeeeeddddccccccRR
TTTEEEEBddeehekkllgjjmglppeeeddddddccc
xSTEEEBddddddeeeeeegjjmgeedddddddddccc
SSSTEBcccdddddddddddhjjjhdddddccccccII
SSpTBIIIIccccccccccccljlccccccIIIIIIDD
MSSTDHDFDDRIIIIIIIIIIIeIIIIIIDDDDDDDDD
SSpFDHFHDDDDDDDDDDDDDDDDDDDDDDDDDDDDDE
--
C.....................................
CL......njnxxxx.......................
nGCCLL..njnrrrr.......................
GGLL..LLnjnrrrrrg.....................
LL...LEEnjnrrrrrmmg...................
QQ..LEEEnjnrrorrjjmmRRRRRRRRR.........
rrrkrEEEnjnooorcgjjjmgccccccccRRRRRR..
rrroEEEEBBdddkkeegjjjmmgeeddddccccccRR
TTTEEEEBddeeeekklllgjjjmmeeeeedddddccc
xSTEEEBdddlddeeeeeeeegjjjmgddddddddccc
SSSTEBcccddddddhddddddghjjjhddccccccII
SSpTBIIIIcccccccccccccccljlcccIIIIIIDD
MSSTDHDFDDRIIIIIIIIIIIIIIeIIIDDDDDDDDD
SSpFDHFHDDDDDDDDDDDDDDDDDDDDDDDDDDDDDE
--
C.....................................
CL......njnxxxx.......................
nGCCLL..njnrrrr.......................
GGLL..LLnjnrrrrrm.....................
LL...LEEnjnrrrrrgmm...................
QQ..LEEEnjnrrorrjjgmmRRRRRRRR.........
rrrkrEEEnjnooorcrjjjgmmcccccccRRRRRR..
rrroEEEEBBdddkkeeeejjjgmmeddhdccccccRR
TTTEEEEBldeeeekklllllljjjmmeeddddddccc
xSTEEEBddddddeeeeeeeeeeejjjmmddddddccc
SSSTEBcccdddddddddddddddddhjjdhcccccII
SSpTBIIIIccccccccccccccccccljlIIIIIIDD
MSSTDHDFDDRIIIIIIIIIIIIIIIIIeDDDDDDDDD
SSpFDHFHDDDDDDDDDDDDDDDDDDDDDDDDDDDDDE
--
C.....................................
CL......njnxxxx.......................
nGCCLL..njnrrrr.......................
GGLL..LLnjnrrrrrg.....................
LL...LEEnjnrrrrrmmg...................
QQ..LEEEnjnrrorrjjmmRRRRRRRRR.........
rrrkrEEEnjnooorcgjjjmgccccccccRRRRRR..
rrroEEEEBBdldkkeegjjjmmgeeddddccccccRR
TTTEEEEBddeeeekklllgjjjmmeeehddddddccc
xSTEEEBddddddeeeeeheegjjjmgddddddddccc
SSSTEBcccdddddddddddddghjjjhddccccccII
SSpTBIIIIcccccccccccccccljlcccIIIIIIDD
MSSTDHDFDDRIIIIIIIIIIIIIIeIIIDDDDDDDDD
SSpFDHFHDDDDDDDDDDDDDDDDDDDDDDDDDDDDDE
--
C.....................................
CL......njnxxxx.......................
nGCCLL..njnrrrr.......................
GGLL..LLnjnrrrrrg.....................
LL...LEEnjnrrrrrmg....................
QQ..LEEEnjnrrorrjmgRRRRRRRRRR.........
rrrkrEEEnjnooorgjjmmccccccccccRRRRRR..
rrroEEEEBBdddkkegjjjmgeeeeddddccccccRR
TTTEEEEBddeheekkllgjjmgleeeeeddddddccc
xSTEEEBddddddeeeeeegjjmghedddddddddccc
SSSTEBcccddeddddddddhjjjhddpddccecccII
SSpTBIIIIccccccccccccljlccccccIIIIIIDD
MSSTDHDFDDRIIIIIIIIIIIeIIIIIIDDDDDDDDD
SSpFDHFHDDDDDDDDDDDDDDDDDDDDDDDDDDDDDE
EOF
)"
    # flames under the cauldron
    ui_add_psprite 13 22 1 rand "$(cat <<'EOF'
EOMSSSSTjDDDDDDDDDEDDDDDEDDEDDDqDDDDDDDDEDDI..PF
ECOSSST.LIDDDEEDDDDDDDDDDDDDEDtqDDDDDDDDDII.....
ECOSMST...LIDDDDfqDDEDDjDDDmfDvtDDDDDjDIq.......
GCEOSTK.....LIIDvqDDmqmjjjjjjtyvqDEDqII.vq......
ECEOSTjy..yq..mmyvqmyqjgggyqgvyvvjjjqyjqyv......
ECEETmEmyjyymmjvyyvjyyqgggyygvyyvgggqyyvyyvjjj..
ECEETEmKyyyyvjtyyyvyyyvffyyyvyyyvgggyyyyyyvggf..
ECEEEmEmvvvvvjvvvvvvvvv.vvvvvvvvvtfvvvvvvvvtgf..
IIIImImImtttttttttttttttttttttttttttttttttttjjjf
IIIIIIIIIqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqffff
--
EOMSSSSTjDDDDDDDDDEDDDqDEDDEDDDDDqDDDDDDEDDI..PF
ECOSSST.LIDDDEEDDDDDDtqDDDDDEDDDtqDDDDDDDII.....
ECOSMST...LIDDDDfDDDtvqjDDDqfDDtvqDDDqDII.......
GCEOSTK.....LIIDqfDDyvtjjjvqjjjyvtEDIvq.........
ECEOSTj...y...mmqymvyvvgggyvqgvyvvjjqyv.y.......
ECEETmEmmjyymmjjqyyvyyvggvyyvgvyyvggvyyvyyjjjj..
ECEETEmKjyyyvjjjyyyyyyvftyyyvvyyyvgtyyyyyyvggf..
ECEEEmEmvvvvvjjvvvvvvvvtvvvvvvvvvvtvvvvvvvvggf..
IIIImImImtttttttttttttttttttttttttttttttttttjjjf
IIIIIIIIIqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqffff
--
EOMSSSSTjDDDDDDDDDEDDDDDEDDEqDDDDDDDDDDDEDDI..PF
ECOSSST.LIDDDEEDDDDDDDDDDDDtqDDDDDDDDDqDDII.....
ECOSMST...LIDDDDfDDqEDDjDDtvqDDDDDDDDtqII.......
GCEOSTK.....LIIDjfvqmmmjjjyvtjjqDDEDIvt..q......
ECEOSTjy...ytqmmmyvqqtyggvyvvgyqjjjjtyvq.qy.....
ECEETmEmyqjyyqjjvyyvjvyygvyyvgyyqgggvyyvxqyyjj..
ECEETEmKyvyyyvjtyyyvjyyyvyyyvyyyvggtyyyvnyyyvf..
ECEEEmEmvvvvvvjvvvvvvvvvvvvvvvvvvffvvvvvvvvvvf..
IIIImImImtttttttttttttttttttttttttttttttttttttjf
IIIIIIIIIqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqff
--
EOMSSSSTjDDDDDDDDDEDDDDDEDDEDDDqDDDDDDDDEDDI..PF
ECOSSST.LIDDDEEDDDDDDDqDDDDDEDDtDDDDDDDDDII.....
ECOSMST...LIDDDDfDDDEDtjDDDmfDDvtDDDDjDII.......
GCEOSTK...q.LIIDjfDDmmvtjjjjjjtyvDEDIII.........
ECEOSTj...qy..mymmmmjtyvgytqggvyvvjyjjj.y.......
ECEETmEmmjqyyqvyyjjjjvyyvyyqggvyyvgyygjjyyjjjj..
ECEETEmKvnyyyvyyyvjjtyyyyyyvfvyyyvyyyvnyyyvggf..
ECEEEmEmvvvvvvvvvvffvvvvvvvv.vvvvvvvvvvvvvvggf..
IIIImImImtttttttttttttttttttttttttttttttttttjjjf
IIIIIIIIIqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqffff
--
EOMSSSSTjDDDDDDDDDEDDDDDEDqEDDDDqDDDDDDDEDDI..PF
ECOSSST.LIDDDEEDDDDDDDDDDtqDEDDtqDDDDDDDDII.....
ECOSMST...LqDDDDfDDDEDDjDvtmfDtvqDDDDjDII.......
GCEOSTK...vqLIIDjfDDqmmjtyvqjjyvtDEDIII.q.......
ECEOSTjq..yvq.mqtymmyqjgvyvvgvyvvjqyjjj.qy......
ECEETmEmmvyyvmjjvyyqyyjgvyyvgvyyvgqyygjjqyyjjj..
ECEETEmKvyyyvjjjyyyyyyvvyyyvvyyyvgyyyvnnyyyvgf..
ECEEEmEmvvvvvtjvvvvvvvvvvvvvvvvvvvvvvvnvvvvvgf..
IIIImImImttttttttttttttttttttttttttttttttttttjjf
IIIIIIIIIqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqfff
--
EOMSSSSTjDDDDDDDDDEDDDDDEDDEDDDDDDDDDDDDEDDI..PF
ECOSSST.LIDDDEEDDDDDDDqDDqDDEDDqDDDqDDDDDII.....
ECOSMST...LIDDDDfDDDEDtjDtDmfDtqDDDqtjDII.......
GCEOSTK.....LIIDjfDDmmvtjvtjjjvtDDEDvtI.........
ECEOSTj.qty...mmmytqjtyvtyvggtyvqjjjvyt...y.....
ECEETmEmmvyymmjjjyyqjvyyvyyvgvyyvgggvyyvxjyyqj..
ECEETEmKjyyyvjjjyyyvtyyyyyyvtyyyvggtyyyvnyyyvf..
ECEEEmEmvvvvvjjvvvvvvvvvvvvvvvvvvtfvvvvvvvvvvf..
IIIImImImtttttttttttttttttttttttttttttttttttttjf
IIIIIIIIIqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqff
EOF
)" 0
    # left candle flame
    ui_add_psprite 9 0 3 seq "$(cat <<'EOF'
....
..u.
..y.
..zz
--
....
..y.
..u.
..zz
--
....
..t.
..w.
..zz
EOF
)" 0
    # right candle flame
    ui_add_psprite 12 70 3 seq "$(cat <<'EOF'
PF
JF
t.
w.
--
PF
JF
y.
u.
--
PF
JF
u.
y.
EOF
)" 0
    # smoke / sparks: scene-row scene-col drift height kind
    SC_SOURCES=("5 46 -1 99 gsmoke" "5 51 -1 99 gsmoke" "5 56 0 99 gsmoke" "5 61 1 99 gsmoke" "6 50 0 8 spark")
}

scene_pixmed() {
    SC_KIND=pix SC_W=56 SC_H=14
    SC_PIX=$(cat <<'EOF'
...nnnn..............L..................................
..njffjn........LLLLLFLL................................
.nnf..nn......LLFFFFLFFLL...............................
.nnfjmnf......LFFFFFFCCFC...............................
..nnnnj......LFFFFFFFFLLC...............................
...nff......LLFFFFFFFFC.................................
...jm.......LLFFFFFFFFC.................................
...jm.......LAAAAAAAAACL....njnxxx......................
....mg...LLCnnnnnnnnnnGGCLLLnjnrrrr.....................
....jm.....LGGGGGGGGGGGLL.LLnjnrrrrg....................
....jm......LLLLLLLLLLLL.LEEnjnrrrrgRRRRRRRR............
....jm.....KNNNNNSrrrArrrrEEnjnoorgmgcccccccccRRRR......
....jm.....KNNNNNNorrrrrrEEEBdddkkgjmgeheeddddccccRRR...
....jm.....KNNNNNNorTTTTTEEBddeeekejmjlleeeeeddddcccRPP.
...jm......KNNNNNOSSSSSSSEBcpdeddddhjjjdddddddccccIIPJFJ
.uujm...CEEKNNNNNOSSSSSSTBIIIcccccccljIccccccDIIIIDDPF.P
.yzjm...CEEEKNNNNOSSSSSSSDHFDDDIIIIIDDIIIIIIDDDDDDDPP..P
.zzzmrrCCEEEKNNNNOMSSSSSpDHFDDDDDDDDDDDDDDDDDDDDDDDPP..P
.zzzjrrCCEKEKNNNNSSSSMSSTDHEDDDDDDDDEDDDDDDEDEDDDDDDP..P
.zzsjroCEEKEGKNNNSSSSSSTDDDDEDDDDDDDDDDDDDDDDDDDDDDDIPPF
.zzzjmCCEEEEEENNEEOSSSSTDDEDDDDDDDDDDDDDDDDDDDDDDDDIIJPJ
.zzzjmCGEEGEEGSEEECOSSTLLDDDEDDDDDDDDDDEDtDDDDDDDII...yy
.bbbbbbbEEEEEECEEECOSST..LIDDDqqDEDjDDjfDvDDDDjIIq....zz
.bnnnnnbEEEEEECEEECEOTK..yLLIDvqDqqjjjjjyyqjjqIIvq....zz
.bbbbbbbEEEEEECEEECEOTjyyyqmmyyvmyqgggygvyvjjqyjyvvjj.zz
iiiiiiiiiEEGEECEEECEEEmKyyyvtyyyyyyffyyvyyvgggyyyyvgg.zz
ixxxxxxxiEIEEECEEECEEmmmvvvtvvvvvvvtvvvvvvvttvvvvvttjjzz
iiiiiiiiIIIIIIIIIIIIIIIImtttttttttttttttttttttttttttjjfz
EOF
)
    # paddle swirling in the glowing pot
    ui_add_psprite 3 22 2 seq "$(cat <<'EOF'
C............................
CL....njnxxx.................
GGCLLLnjnrrrr................
GLL.LLnjnrrrrg...............
LL.LEEnjnrrrrgRRRRRRRR.......
rrrrEEnjnoorgmgcccccccccRRRR.
rrrEEEBdddkkgjmgeheeddddccccR
TTTEEBddeeekejmjlleeeeeddddcc
SSSEBcpdeddddhjjjdddddddccccI
SSTBIIIcccccccljIccccccDIIIID
--
C............................
CL....njnxxx.................
GGCLLLnjnrrrr................
GLL.LLnjnrrrrg...............
LL.LEEnjnrrrrggRRRRRRR.......
rrrrEEnjnoorgjmmccccccccRRRR.
rrrEEEBdddkkejjjmeeeddddccccR
TTTEEBddedekelgjjglpeedddddcc
SSSEBccdddddddddhjjhddddccccI
SSTBIIIcccccccccIjIccccDIIIID
--
C............................
CL....njnxxx.................
GGCLLLnjnrrrr................
GLL.LLnjnrrrrm...............
LL.LEEnjnrrrrmmmRRRRRR.......
rrrrEEnjnoorcjjjmcccccccRRRR.
rrrEEEBdddkkegjjjmmeddddccccR
TTTEEBddeeekeleejjmmeeeddddcc
SSSEBccdddddhddddghjjhddccccI
SSTBIIIcccccccccccIllccDIIIID
--
C............................
CL....njnxxx.................
GGCLLLnjnrrrr................
GLL.LLnjnrrrrm...............
LL.LEEnjnrrrrmmmmRRRRR.......
rrrrEEnjnoorcjjjgmccccccRRRR.
rrrEEEBdddkkeeljjgmmdeddccccR
TTTEEBldeeekelllljjjmedddddcc
SSSEBccdddddddddddddhjjdccccI
SSTBIIIccccccccccccccljDIIIID
--
C............................
CL....njnxxx.................
GGCLLLnjnrrrr................
GLL.LLnjnrrrrm...............
LL.LEEnjnrrrrmmmRRRRRR.......
rrrrEEnjnoorcjjjmcccccccRRRR.
rrrEEEBdeekkegjjjmmeddddccccR
TTTEEBddeeekellejjmmeddddddcc
SSSEBccddddddddddghjjhddccccI
SSTBIIIcccccccccccIllccDIIIID
--
C............................
CL....njnxxx.................
GGCLLLnjnrrrr................
GLL.LLnjnrrrrg...............
LL.LEEnjnrrrrggRRRRRRR.......
rrrrEEnjnoorgjmmccccccccRRRR.
rrrEEEBdddkkejjjmeeeddddccccR
TTTEEBddddekelgjjgleeedddddcc
SSSEBccddeddddddhjjhdpddceccI
SSTBIIIcccccccccIjIccccDIIIID
EOF
)"
    # flames under the cauldron
    ui_add_psprite 10 17 1 rand "$(cat <<'EOF'
EOSSSSTDDEDDDDDDDDDDDDDDDDDDDDDDDDIIJ
ECOSSTLLDDDEDDDDDDDDDDEDtDDDDDDDII...
ECOSST..LIDDDqqDEDjDDjfDvDDDDjIIq....
ECEOTK..yLLIDvqDqqjjjjjyyqjjqIIvq....
ECEOTjyyyqmmyyvmyqgggygvyvjjqyjyvvjj.
ECEEEmKyyyvtyyyyyyffyyvyyvgggyyyyvgg.
ECEEmmmvvvtvvvvvvvtvvvvvvvttvvvvvttjj
IIIIIIImtttttttttttttttttttttttttttjj
--
EOSSSSTDDEDDDDDDDDDDDDDDDDDDDDDDDDIIJ
ECOSSTLLDDDEDDDDDtDDDDEDDtqDDDDDII...
ECOSST..LIDDDfDDvvjDDqfDDvqDDqDI.....
ECEOTK..y.LIqqfDyvjjjvjjyvtjDvq......
ECEOTjmmyymmqqyvyvggyyqgvvvjjyvyyjjj.
ECEEEmKjyyvjjyyyyyftyyvvyyvgtyyyyvgg.
ECEEmmmvvvtjvvvvvvtvvvvvvvttvvvvvtgjj
IIIIIIImtttttttttttttttttttttttttttjj
--
EOSSSSTDDEDDDDDDDDDDDDDDDDDDDDDDDDIIJ
ECOSSTLLDDDEDDDDDDDDDDqDDDDDDDqDII...
ECOSST..LIDDDfDqmDjDDvqDDDDDDtqIq....
ECEOTK...LLImjvqmmjjyytjqDjjDvt.q....
ECEOTjyyjyqmmyyqqyggvyvgyjjjjyvqqyyj.
ECEEEmKyyyyjtyyvjyyvyyvyyvggtyyvyyyv.
ECEEmmmvvvvjvvvvvvvvvvvvvvftvvvvvvvtj
IIIIIIImttttttttttttttttttttttttttttj
--
EOSSSSTDDEDDDDDDDDDDDDDDDDDDDDDDDDIIJ
ECOSSTLLDDDEDDDDDDDDDDEDDDDDDDDDII...
ECOSST..LIDDDfDDmDjDDjfDDtDDDjII.....
ECEOTK..qLLIDmmDmmtjjjjjyvDEDII......
ECEOTjmmqyymymmmjyvyyqggvvvyyjjyyjjj.
ECEEEmKvyyyyyyvjtyyyyyfvyyvyyvnyyvgg.
ECEEmmmvvvvvvvtfvvvvvvtvvvvvvvvvvtgjj
IIIIIIImtttttttttttttttttttttttttttjj
--
EOSSSSTDDEDDDDDDDDDDDEDDDDDDDDDDDDIIJ
ECOSSTLLDDDEDDDDDDDDtqEDDqDDDDDDII...
ECOSST..LqDDDfDDEDjDvtfDvqDDDjII.....
ECEOTK..vqLIDjfDqmjyyvjyytDEDIIqy....
ECEOTjmmyvqmqyymyjgvyvgvyvqqyjjqyyjj.
ECEEEmKvyyvjjyyyyyvyyyvyyvgyyvnnyyvg.
ECEEmmmvvvtjvvvvvvvvvvvvvvvvvvtvvvtgj
IIIIIIImttttttttttttttttttttttttttttj
--
EOSSSSTDDEDDDDDDDDDDDDDDDDDDDDDDDDIIJ
ECOSSTLLDDDEDDDDDDDDqDEDDDDDqDDDII...
ECOSST..LIDDDfDDmDjDtDfDtDDDqjII.....
ECEOTK.qy.LImjfDmmtjvtjjvDjjvtI......
ECEOTjmqyymmmyyqjyvyyvgyyqjjvytvjyyq.
ECEEEmKjyyvjjyyvtyyyyytyyvggtyyvyyyv.
ECEEmmmvvvtjvvvvvvvvvvvvvvttvvvvvvvtj
IIIIIIImttttttttttttttttttttttttttttj
EOF
)" 0
    # left candle flame
    ui_add_psprite 7 0 3 seq "$(cat <<'EOF'
...j
.uuj
.yzj
.zzz
--
...j
.yyj
.uzj
.zzz
--
...j
.ttj
.wzj
.zzz
EOF
)" 0
    # right candle flame
    ui_add_psprite 10 54 3 seq "$(cat <<'EOF'
PJ
uu
zz
zz
--
PJ
yy
zz
zz
--
PJ
tt
zz
zz
EOF
)" 0
    # smoke / sparks: scene-row scene-col drift height kind
    SC_SOURCES=("4 36 -1 99 gsmoke" "4 40 -1 99 gsmoke" "4 44 0 99 gsmoke" "4 47 1 99 gsmoke" "5 39 0 6 spark")
}

scene_pixside() {
    SC_KIND=pix SC_W=88 SC_H=36
    ui_set_palette "a28 b35 c41 d47 e52 f94 g121 h136 i137 j157 k178 l180 m202 n220 o223 p233 q235 r237 s239 t241 u243 v245 w247 x249 y253 z255"
    # the picture: 2 rows of the text below = 1 row of the terminal; a letter is a colour (see the palette above), . = nothing
    SC_PIX=$(cat <<'EOF'
........................................................................................
........................................................................................
........................................................................................
....................ttttttttt...........................................................
...................trrrtrrrrrt..........................................................
...................tsrrtrsrrrrt.........................................................
..................tsrrrstpppprrt........................................................
..................tsrsrrrrqt.trrt.......................................................
.................tssrrrrrrrqt.trp.......................................................
.................tsrrrsrrrrqp.trrt......................................................
................tsrrsrrrrrrrqt.tpp......................................................
..........f.....tssrrrrrrrrrrqt.........................................................
.........fff...tqqqqqqqqqkkkqqq.........................................................
..........fff.ptpppppppppkpkpppt........................................................
...........ffffqqqqqqqqqqhhhqqqpt.......................................................
.........ppprfffrrrrrrrrrrrrrrrrrppt....................................................
.........prrrrfffttttttttttttttttrrrpt..................................................
.........ttttttfff......illlllllltttttt.................................................
................ffffyyyyillllllllo.....t................................................
................wyfffyyyilllllllllo.....................................................
................wyyfffyyilllllllllo.....................................................
................wyyyfffyillllllllllo....................................................
................wyyyyfffflllllllllo.....................................................
................wyyyyyyfffllllllllo.....................................................
................wyyyyyyyfffllllllo......................................................
...............wyyyyyyyyiffflozzzzz.....................................................
...............wyyyyyyyyxzfffzzzzzzz....................................................
...............wyyyyyyyyxzzffffzzzzz....................................................
...............wyyyyyyyyxzzzzfffzzzzz...................................................
...............wyyyyyyyyqqqqqqqffzzooo..................................................
..............pwyyyyyyqqrrrrrhkqfoollll.................................................
..............pwyyyqqqqrrrrrrhfollllillo................................................
.............pqqwyyqqqqrrrrprhklllillill................................................
.............pqqwyyqqqqprrprrhflllillill................................................
.............pqqqwyqqqprrrprrhkizlillill................................................
............pqqqqwyqqqprrrprrhfrzzillilf................................................
............pqqqqwyqqqprrrprrhkrzzziiiffff..............................................
...........pqqqqqqwqqqprrrprrhftzzzzz...fff.............................................
...........pqqqqqqwqqqprrrprtttzzzzz.....fff............................................
...........pqqqqqqqqqqprrtptzzzzzzzz......fff...........................................
...........pqqqqqqqqqqpttqxzzzzzzzz........ffff.........................................
..........pqqqqqqqqqqqqqqqqxzzzzzzz..........fff...xxxxxxxxxxxxxxxxxxxxx................
..........pqqqqqqqqqqqqqqqqxzzzzzzz..........xfffxxaaaaaaaaaaaaaaaaaaaaaxxxxxx..........
..........pqqqqqqqqqqqqqqqqqxzzzzzqs.....xxxxaafffabbbbbbbbbbbbbbbbbbbbbaaaaaaxxxx......
..........pqqqqqqqqqqqqqqqqqxzzzzzqs...xxuaaabbbffffcccdddddddddddddccccbbbbbbaaauxx....
.........pqqqqqqqqqqqqqqqqqqqxzzzqqs..xuuabbbbccccfffddddddddddddddddddccccccbbbbauux...
.........pqqqqqqqqqqqqqqqqqqqxzzqqs.vvxuuubbbbcccccfffcdddddddddddddcccccccccbbbbuuurv..
.........pqqqqqqqqqqqqqqqqqqqqxzqqsvsqsxruuuubbbbbbcfcccccccccccccccccccbbbbbbuuuurrqsv.
.........pqqqqqqqqqqqqqqqqqqqqzqqqsvq.vq.xrrruuuuuubbbbbbbbbbbbbbbbbbbbbuuuuuurrrrvq.vq.
........pqqqqqqqqqqqqqqqqqqqqqqqqqssq.vsv...pxrrrrruuuuuuuuuuuuuuuuuuuuurrrrrrr..vsq.vsv
........pqqqqqqqqqqqqqqqqqqqqqqqqsvq...vq..rrpqqrqpxrrrrrrrrrrrrrrrrrrrrppqqqqqr.vq...vq
........pqqqqqqqqqqqqqqqqqqqqqqqqsvq...vq..rqqqqrrqqqqqqpqqqqqrqqqqqqqqrrrqqrqqp.vq...vq
........pqqqqqqqqqqqqqqqqqqqqqqqqsvq...vq.rqrpqqqqqqqrqqqqqqrqqqqqqqqqqpqrpqrqqqrvq...vq
.......pqqqqqqqqqqqqqqqqqqqqqqqqqsvq...vqrqqrqqqqqqqqqqqqqqqqqqqqqqqqrrqpqpqqqrqqvq...vq
.......pqqqqqqqqqqqqqqqqqqqqqqqqqsvsv.vsqrqrqqqqqrqqqrqqpqqpqqqpqqqrqpqqrqqqqrqqqvsv.vsq
.......pqqqqqqqqqqqqqqqqqqqqqqqqqs.vq.vq.pqqpqqqpqpqqqqqqrqqrrprqqqqqrqpqpqqrqqrqpvq.vq.
.......pqqqqqqqqqqqqqqqqqqqqqqqqqs.vsvsq.rqqqqqqqqqqqprpqqrpqqqqqqqrqqqqqqqqqpqqqrvsvsq.
......pqqqqqqqqqqqqqqqqqqqqqqqqqqs..vqq..rpqpqppqqqqqqqqqqqrqqpqqqqqrqqqqqqqqqqprp.vqq..
......pqqqqqqqqqqqqqqqqqqqqqqqqqqs.......rqqqqqqpqqqqqpqqpqqrqqqqqqqqqprqqqqppqqqp......
......pqqqqqqqqqqqqqqqqqqqqqqqqqqs........rqqqrqrqqpmqqqqmqrqrmqrqqqqqqqppqqqrqqp.......
......pqqqqqqqqqqqqqqqqqqqqqqqqqqs.........pqqrqqqqqmqqqqmprqqmqqqrqqqqqqqqqpqqp........
.....pqqqqqqqqqqqqqqqqqqqqqqqqqqqs.........rqpqmqqqmmmqqmmmrrmmmqqqrrpqpqqqqqqqp........
.....pqqqqqqqqqqqqqqqqqqqqqqqqqqqs..........rppmqrqmnmqqmnmqqmnmqqqpqqqqqqrrqpp.........
.....pqqqqqqqqqqqqqqqqqqqqqqqqqqqs............mmmqqmnmqqmnmqqmnmqqqqpqqqmqqqp...........
.....pqqqqqqqqqqqqqqqqqqqqqqqqqqqs........m...mnmqpmnmqqmnmqqmnmqqrqqqqqmqpp............
....pqqqqqqqqqqqqqqqqqqqqqqqqqqqqs........m...mnmrmnnnmmnnnmmnnnmqqmrqqmmm...m..........
....pqqqqqqqqqqqqqqqqqqqqqqqqqqqqs....eeemmmemnnnmmnnnmmnnnmmnnnmemmmeemnmeemmmeeeeeeee.
....pqqqqqqqqqqqqqqqqqqqqqqqqqqqqs....eeemnmemnnnmmnnnmmnnnmmnnnmemmmemmnmmemmmeeeeeeee.
....pqqqqqqqqqqqqqqqqqqqqqqqqqqqqs....eemnnnmmnnnmmnnnmmnnnmmnnnmmmnmmmnnnmmmnmmeeeeeee.
...pqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs....eemnnnmnnnnmnnnnmnnnnmnnnnnmnnnmmnnnmmnnnmeeeeeee.
...pqqqqqqqqqqqqqqqqqqqqqqqqqqqqqs....emnnnnmnnnnmnnnnmnnnnmnnnnmnnnnmnnnnmnnnnnmeeeeee.
......................................eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.
EOF
)
    # stir: 6 frames of 45x11 cells, every 2 tick(s), seq
    ui_add_psprite 14 33 2 seq "$(cat <<'SPRITE_END'
zzzz.........................................
zzooo........................................
oollll.......................................
lllillo......................................
lillill......................................
lillill......................................
lillill......................................
zillilf......................................
zziiiffff....................................
zzzz...fff...................................
zzz.....fff..................................
zzz......fff.................................
zz........ffff...............................
zz..........fff...xxxxxxxxxxxxxxxxxxxxx......
zz..........xfffxxaaaaaaaaaaaaaaaaaaaaaxxxxxx
zqs.....xxxxaafffabbbbbbjbbbbbbbbbbbbbbaaagaa
zqs...xxuaaabbbffffcccdddddddddddddccccbbbbbb
qqs..xuuabbbbccccfffddddddddddddddddddccccccb
qs.vvxuuubbbbcccccfffcdddddddddddddcccccjcccb
qsvsqsxruuuubbbbgbcfccccccjcccccccjccccbbbbbb
qsvq.vq.xrrruuuuuubbbbbbbbbbbbbbbbbbbbbuuuuuu
qssq.vsv...pxrrrrruuuuuuuuuuuuuuuuuuuuurrrrrr
--
zzzz.........................................
zzooo........................................
oollll.......................................
lllillo......................................
lillill......................................
lillill......................................
lillill......................................
zillilfff....................................
zziii..ffff..................................
zzzz.....fff.................................
zzz.......ffff...............................
zzz.........ffff.............................
zz............fff............................
zz.............ffffxxxxxxxxxxxxxxxxxxxx......
zz..........xxxxxffffaaaaaaaaaaaaaaaaaaxxxxxx
zqs.....xxxxaaaaaabfffbbbbbbbbbbbbbbbbbaaaaaa
zqs...xxuaaabbbbbbccffffdddddddddddccccbbbbbb
qqs..xuuabbbbccgcccdddfdddddddjdddddddccccccb
qs.vvxuuubbbbcccccccccdddddddddddddcccgcccccb
qsvsqsxruuuubbbbbbccccccccccccccccccjccbbbbbb
qsvq.vq.xrrruuuuuubbbbbbbbbbbbbbbbbbbbbuuuuuu
qssq.vsv...pxrrrrruuuuuuuuuuuuuuuuuuuuurrrrrr
--
zzzz.........................................
zzooo........................................
oollll.......................................
lllillo......................................
lillill......................................
lillill......................................
lillill......................................
zillilfff....................................
zziii...fff..................................
zzzz......fff................................
zzz.........fff..............................
zzz............fff...........................
zz...............fff.........................
zz................xfffxxxxxxxxxxxxxxxxx......
zz..........xxxxxxaaafffaaaaaaaaaaaaaaaxxxxxx
zqs.....xxxxaaaaaabbbbbfffbbbbbbbbbbbbbaaaaaa
zqs...xxuaaabbbbbbccccdddfffdddddddccccbbbbbb
qqs..xuuabbbbccjcccddddddddfddddddddddccccccb
qs.vvxuuubbbbcccccccccdjdddddddddddcccccccccb
qsvsqsxruuuubbbbbjcccjccccccccjccccccccbbjbbb
qsvq.vq.xrrruuuuuubbbbbbbbbbbbbbbbbbbbbuuuuuu
qssq.vsv...pxrrrrruuuuuuuuuuuuuuuuuuuuurrrrrr
--
zzzz.........................................
zzooo........................................
oollll.......................................
lllillo......................................
lillill......................................
lillill......................................
lillill......................................
zillilfff....................................
zziii...fff..................................
zzzz......fff................................
zzz.........fff..............................
zzz...........ff.............................
zz..............ff...........................
zz...............fffxxxxxxxxxxxxxxxxxxx......
zz..........xxxxxxafffaaaaaaaaaaaaaaaaaxxxxxx
zqs.....xxxxaaaaaabbbfffbbbbbbbbbbbbbbbaaajaa
zqs...xxuaaabbbbbbccccdfffdddddddddjcccbgbbbb
qqs..xuuabbbbccccccddddddfffddddddddddccccccb
qs.vvxuuubbbbcccccccccdddddfffdddddcccjcccccb
qsvsqsxruuuubbbbbbcccccccccccfcccgcccccbbgbbb
qsvq.vq.xrrruuuuuubbbbbbbbbbbbbbbbbbbbbuuuuuu
qssq.vsv...pxrrrrruuuuuuuuuuuuuuuuuuuuurrrrrr
--
zzzz.........................................
zzooo........................................
oollll.......................................
lllillo......................................
lillill......................................
lillill......................................
lillill......................................
zillilff.....................................
zziii..fff...................................
zzzz....fff..................................
zzz.......fff................................
zzz........fff...............................
zz...........fff.............................
zz............fff.xxxxxxxxxxxxxxxxxxxxx......
zz..........xxxxfffaaaaaaaaaaaaaaaaaaaaxxxxxx
zqs.....xxxxaaaaafffbbbbbbbbbbbbbbbbbbbaaaaaa
zqs...xxuaaabbbbbbcfffdddddddddddddccccbbbbbb
qqs..xuuabbbbccccccdfffddddddddddddjddccccccb
qs.vvxuuubbbbcccccccccfffddddddddjdcgcccccccb
qsvsqsxruuuubbbbbbcccccfffjccccccccccccbjbbbb
qsvq.vq.xrrruuuuuubbbbbbbfffbbbbbbbbbbbuuuuuu
qssq.vsv...pxrrrrruuuuuuuufuuuuuuuuuuuurrrrrr
--
zzzz.........................................
zzooo........................................
oollll.......................................
lllillo......................................
lillill......................................
lillill......................................
lillill......................................
zillilff.....................................
zziii.fff....................................
zzzz...fff...................................
zzz.....fff..................................
zzz......fff.................................
zz........fff................................
zz..........fff...xxxxxxxxxxxxxxxxxxxxx......
zz..........xfffxxaaaaaaaaaaaaaaaaaaaaaxxxxxx
zqs.....xxxxaafffajbbbbbbbbbbjbbbbbbbbbaaaaaa
zqs...xxuaaabbbfffccccdddddddddddddccccgbbbbb
qqs..xuuabbbbcccfffdddddddddddddddddddccccccb
qs.vvxuuubbbbccccffffcdddddddddddddcccccccccb
qsvsqsxruuuubbbbjbcfffcccccccccccccccccbbbbbb
qsvq.vq.xrrruuuuuubbfffbbbbbbbbbbbbbbbbuuuuuu
qssq.vsv...pxrrrrruuufuuuuuuuuuuuuuuuuurrrrrr
SPRITE_END
    )"
    # flames: 6 frames of 44x6 cells, every 1 tick(s), rand
    ui_add_psprite 28 40 1 rand "$(cat <<'SPRITE_END'
.rqqqqqqqqqqqprpqqrpqqqqqqqrqqqqqqqqqpqqqrvs
.rpqpqppqqqqqqqqqmqrqqmqqqqqrqqqqqqqqqqprp.v
.rqqqqqqpqqqqqpqqmqqrqmqqqqqqqprqqqqppqqqp..
..rqqqrqrqqpmqqqqmqrqrmqrqqqqqqqppqqqrqqp...
...pqqrmqqqqmqqqqmprqqmqqqrqqqqqqqqqpqqp....
...rqpqmqqqmmmqqmmmrrmmmqqqrrpqpqqqqqqqp....
....rppmqrqmnmqqmnmqqmnmqqqpqqqqqqrrqpp.....
......mmmqqmnmqqmnmqqmnmqqqqpqqqmqqqp.......
..m...mnmqpmnmqqmnmqqmnmqqrqqqqqmqpp........
..m...mnmrmnnnmmnnnmmnnnmqqmrqqmmm...m......
emmmemnnnmmnnnmmnnnmmnnnmemmmeemnmeemmmeeeee
emnmemnnnmmnnnmmnnnmmnnnmemmmemmnmmemmmeeeee
--
.rqqqqqqqqqqqprpqqrpqqqqqqqrqqqqqqqqqpqqqrvs
.rpqpqppqqqqqqqqqqqrqqpqqqqqrqqqqqqqqqqprp.v
.rqqqqqqpqqqqqpqqpqqrqqqqqqqqqprqqqqppqqqp..
..rqqqrqrqqpqqqqqmqrqrqqrqqqqqqqppqqqrqqp...
...pqqrmqqqqqqqqqmprqqqqqqrqqqqqqqqqpqqp....
...rqpqmqqqmmmqqmmmrrmmmqqqrrpqpqqqqqqqp....
....rppmqrqmnmqqmnmqqmnmqqqpqqqqqqrrqpp.....
......mmmqqmnmqqmnmqqmnmqqqqpqqqmqqqp.......
..mm..mnmqpmnmqqmnmqqmnmqqrqqqqqmqmp..m.....
..mm..mnmrmnnnmmnnnmmnnnmqqmrqqmmmm..mm.....
emmmemnnnmmnnnmmnnnmmnnnmemmmeemnmeemmmeeeee
emnmemnnnmmnnnmmnnnmmnnnmemmmemmnmmemmmeeeee
--
.rqqqqqqqqqqqprpqqrpqqqqqqqrqqqqqqqqqpqqqrvs
.rpqpqppqqqqqqqqqqqrqqpqqqqqrqqqqqqqqqqprp.v
.rqqqqqqpqqqqqpqqmqqrqqqqqqqqqprqqqqppqqqp..
..rqqqrqrqqpqqqqqmqrqrmqrqqqqqqqppqqqrqqp...
...pqqrmqqqqqqqqqmprqqmqqqrqqqqqqqqqpqqp....
...rqpqmqqqmmmqqmmmrrmmmqqqrrpqpqqqqqqqp....
....rppmqrqmnmqqmnmqqmnmqqqpqqqqqqrrqpp.....
......mmmqqmnmqqmnmqqmnmqqqqpqqqmqqqp.......
..mm..mnmqpmnmqqmnmqqmnmqqrqqqqqmqmp........
..mm..mnmrmnnnmmnnnmmnnnmqqmrqqmmmm..m......
emmmemnnnmmnnnmmnnnmmnnnmemmmeemnmeemmmeeeee
emnmemnnnmmnnnmmnnnmmnnnmemmmemmnmmemmmeeeee
--
.rqqqqqqqqqqqprpqqrpqqqqqqqrqqqqqqqqqpqqqrvs
.rpqpqppqqqqqqqqqqqrqqpqqqqqrqqqqqqqqqqprp.v
.rqqqqqqpqqqqqpqqmqqrqqqqqqqqqprqqqqppqqqp..
..rqqqrqrqqpqqqqqmqrqrmqrqqqqqqqppqqqrqqp...
...pqqrmqqqqqqqqqmprqqmqqqrqqqqqqqqqpqqp....
...rqpqmqqqmmmqqmmmrrmmmqqqrrpqpqqqqqqqp....
....rppmqrqmnmqqmnmqqmnmqqqpqqqqqqrrqpp.....
......mmmqqmnmqqmnmqqmnmqqqqpqqqmqqqp.......
..mm..mnmqpmnmqqmnmqqmnmqqrqqqqqmqpp........
..mm..mnmrmnnnmmnnnmmnnnmqqmrqqmmm...m......
emmmemnnnmmnnnmmnnnmmnnnmemmmeemnmeemmmeeeee
emnmemnnnmmnnnmmnnnmmnnnmemmmemmnmmemmmeeeee
--
.rqqqqqqqqqqqprpqqrpqqqqqqqrqqqqqqqqqpqqqrvs
.rpqpqppqqqqmqqqqmqrqqpqqqqqrqqqqqqqqqqprp.v
.rqqqqqqpqqqmqpqqmqqrqqqqqqqqqprqqqqppqqqp..
..rqqqrqrqqpmqqqqmqrqrqqrqqqqqqqppqqqrqqp...
...pqqrqqqqqmqqqqmprqqmqqqrqqqqqqqqqpqqp....
...rqpqqqqqmmmqqmmmrrmmmqqqrrpqpqqqqqqqp....
....rppqqrqmnmqqmnmqqmnmqqqpqqqqqqrrqpp.....
......mmmqqmnmqqmnmqqmnmqqqqpqqqmqqqp.......
..mm..mnmqpmnmqqmnmqqmnmqqrqqqqqmqpp..m.....
..mm..mnmrmnnnmmnnnmmnnnmqqmrqqmmm...mm.....
emmmemnnnmmnnnmmnnnmmnnnmemmmeemnmeemmmeeeee
emnmemnnnmmnnnmmnnnmmnnnmemmmemmnmmemmmeeeee
--
.rqqqqqqqqqqqprpqqrpqqqqqqqrqqqqqqqqqpqqqrvs
.rpqpqppqqqqmqqqqmqrqqpqqqqqrqqqqqqqqqqprp.v
.rqqqqqqpqqqmqpqqmqqrqqqqqqqqqprqqqqppqqqp..
..rqqqrqrqqpmqqqqmqrqrmqrqqqqqqqppqqqrqqp...
...pqqrqqqqqmqqqqmprqqmqqqrqqqqqqqqqpqqp....
...rqpqqqqqmmmqqmmmrrmmmqqqrrpqpqqqqqqqp....
....rppqqrqmnmqqmnmqqmnmqqqpqqqqqqrrqpp.....
......mmmqqmnmqqmnmqqmnmqqqqpqqqmqqqp.......
..m...mnmqpmnmqqmnmqqmnmqqrqqqqqmqpp........
..m...mnmrmnnnmmnnnmmnnnmqqmrqqmmm...m......
emmmemnnnmmnnnmmnnnmmnnnmemmmeemnmeemmmeeeee
emnmemnnnmmnnnmmnnnmmnnnmemmmemmnmmemmmeeeee
SPRITE_END
    )" 0
    # smoke / sparks: scene-row scene-col drift height kind
    SC_SOURCES=("20 49 -1 99 gsmoke" "20 55 -1 99 gsmoke" "20 61 0 99 gsmoke" "20 67 1 99 gsmoke" "20 73 1 99 gsmoke" "21 61 0 8 spark")
}

scene_pixsidem() {
    SC_KIND=pix SC_W=66 SC_H=27
    ui_set_palette "a28 b35 c41 d47 e52 f94 g121 h136 i137 j157 k178 l180 m202 n220 o223 p233 q235 r237 s239 t241 u243 v245 w247 x249 y253 z255"
    # the picture: 2 rows of the text below = 1 row of the terminal; a letter is a colour (see the palette above), . = nothing
    SC_PIX=$(cat <<'EOF'
..................................................................
..................................................................
...............ttttttt............................................
..............trrtrrrrt...........................................
..............tsrtrsrrrt..........................................
..............trsrtrpptrt.........................................
.............tsrrrrrrt.tp.........................................
.............tsrrsrrrp.trt........................................
............tsrsrrrrrrttpp........................................
.......ff..tqqqqqqqkkqqq..........................................
........ff.tpppppppkpppt..........................................
.......pprffrrrrrrrrrrrrtpt.......................................
.......prrrffttttttttttttrrpt.....................................
.......tttttff....illllllttttt....................................
............wyfyyyillllllo........................................
............wyyffyilllllllo.......................................
............wyyffyilllllllo.......................................
............wyyyyfflllllllo.......................................
............wyyyyyfflllllo........................................
...........wyyyyyyifflozzzz.......................................
...........wyyyyyyxzffzzzzz.......................................
...........wyyyyyyxzzzffzzzz......................................
...........wyyyyyyqqqqqqfzzoo.....................................
...........wyyyyyqrrrrhqlollll....................................
..........pqwyyqqrrrrrhlllllil....................................
..........pqwyyqqqrrrrhlllllil....................................
.........pqqqwyqqrrrrrhrzzllil....................................
.........pqqqwyqqrrrrrhrzzziifff..................................
........pqqqqqwqqrrrrrhtzzzz..fff.................................
........pqqqqqqqqrrtpzzzzzz....fff................................
........pqqqqqqqqttqzzzzzzz.....ffff..............................
........qqqqqqqqqqqqxzzzzzz.......ff..xxxxxxxxxxxxxxxx............
........qqqqqqqqqqqqqzzzzzz....xxxxffxabbbbbbbbbbbbbbbxxxxxxxx....
........qqqqqqqqqqqqqxzzzzs..xxuaabbfffccddddddddddcccbbbbbaaux...
.......pqqqqqqqqqqqqqqxzzqs..xuabbbcccffddddddddddddddccccbbbaux..
.......pqqqqqqqqqqqqqqxzqqsvvxuuuubccccffcdddddddddcccccccbuuuurv.
.......pqqqqqqqqqqqqqqqzqqvq.v.xrruuuuubbbbbbbbbbbbbbbuuuuurrrv.vq
......pqqqqqqqqqqqqqqqqqqqsq.vv..pxrrruuuuuuuuuuuuuuuurrrrrr.vs.vv
......pqqqqqqqqqqqqqqqqqqsv..vq.rrqqrrqrrrrrrrrrrrrrrrrrqrqq.vq..v
......pqqqqqqqqqqqqqqqqqqsv..vq.rrpqqqqqrqqqqrqqqqqqqqqrqrqqrvq..v
.....pqqqqqqqqqqqqqqqqqqqsv..vqrqrqqqqqqqqqqqqqqqqqqrrpqqqqrqvq..v
.....pqqqqqqqqqqqqqqqqqqqsvv.vqrqqqqqrqqrqqrqrrpqqqqrqrqqrrqqvv.vq
.....pqqqqqqqqqqqqqqqqqqqsvsvs.rqqqqqqqqprqqrqqqqqrqqqqqqqpqqrvvsq
.....qqqqqqqqqqqqqqqqqqqqs.vqq.rqpqpqqqqqqqqrqqqqqqrqqqqqqqqrpvqq.
.....qqqqqqqqqqqqqqqqqqqqs.....rqqqqrqqqqqqpqrrqrqqqqqqqqqrqqp....
.....qqqqqqqqqqqqqqqqqqqqs......pqqrqqqmqqqmrqqqqqrqqqqqqpqq......
....pqqqqqqqqqqqqqqqqqqqqs......rqpqqqqmmqmmrrmmqqrrpqqqqqqq......
....pqqqqqqqqqqqqqqqqqqqqs.......rpmqrqnmqmnqqmnqqqqqqqqrqp.......
....pqqqqqqqqqqqqqqqqqqqqs......m..nmqpnmqmnqqmnqqrqqqmqp.........
...pqqqqqqqqqqqqqqqqqqqqqs......m..nmrnnnmnnnmnnmqqrqqmm..m.......
...pqqqqqqqqqqqqqqqqqqqqqs...eemmemnnmnnnmnnnmnnmemmemnmemmmeeeeee
...pqqqqqqqqqqqqqqqqqqqqqs...emnnmmnnmnnnmnnnmnnmmnmmnnnmmnmeeeeee
..pqqqqqqqqqqqqqqqqqqqqqqs...emnnmnnnmnnnnnnnnnnnmnnmnnnmnnneeeeee
...qqqqqqqqqqqqqqqqqqqqqqs...ennnmnnnmnnnennennnmnnnmnnnennnmeeeee
EOF
)
    # stir: 6 frames of 35x9 cells, every 2 tick(s), seq
    ui_add_psprite 10 24 2 seq "$(cat <<'SPRITE_END'
zzz................................
zzzz...............................
fzzoo..............................
lollll.............................
llllil.............................
llllil.............................
zzllil.............................
zzziifff...........................
zzzz..fff..........................
zzz....fff.........................
zzz.....ffff.......................
zzz.......ff..xxxxxxxxxxxxxxxx.....
zzz....xxxxffxabbbbjbbbbbbbbbbxxxxx
zzs..xxuaabbfffccddddddddddcccbbbbb
zqs..xuabbbcccffddddddddddddddccccb
qqsvvxuuuubccgcffcdddddddddccccjccb
qqvq.v.xrruuuuubbbbbbbbbbbbbbbuuuuu
qqsq.vv..pxrrruuuuuuuuuuuuuuuurrrrr
--
zzz................................
zzzz...............................
fzzoo..............................
lollll.............................
llllil.............................
llllil.............................
zzllilff...........................
zzzii.fff..........................
zzzz....ff.........................
zzz......ffff......................
zzz........fff.....................
zzz.........fffxxxxxxxxxxxxxxx.....
zzz....xxxxxxxfffabbbbbbbbbbbbxxxxx
zzs..xxuaabbbbccfffddddddddcccbbbbb
zqs..xuabbbcgccddfdddddjddddddccccb
qqsvvxuuuubcccccccdddddddddcjcccccb
qqvq.v.xrruuuuubbbbbbbbbbbbbbbuuuuu
qqsq.vv..pxrrruuuuuuuuuuuuuuuurrrrr
--
zzz................................
zzzz...............................
fzzoo..............................
lollll.............................
llllil.............................
llllil.............................
zzllilff...........................
zzzii..ff..........................
zzzz....fff........................
zzz.......ffff.....................
zzz...........ff...................
zzz...........xffxxxxxxxxxxxxx.....
zzz....xxxxxxxabbfffabbbbbbbbbxxxxx
zzs..xxuaabbbbcccdddffdddddcccbbbbb
zqs..xuabbbcjccddddddfddddddddccccb
qqsvvxuuuubcccccccjddddddddcccccccb
qqvq.v.xrruuuuubbbbbbbbbbbbbbbuuuuu
qqsq.vv..pxrrruuuuuuuuuuuuuuuurrrrr
--
zzz................................
zzzz...............................
fzzoo..............................
lollll.............................
llllil.............................
llllil.............................
zzllilff...........................
zzzii..ff..........................
zzzz....fff........................
zzz.......fff......................
zzz..........ff....................
zzz...........ffxxxxxxxxxxxxxx.....
zzz....xxxxxxxaffffbbbbbbbbbbbxxxxx
zzs..xxuaabbbbcccdfffddddddjccbgbbb
zqs..xuabbbccccdddddffddddddddccccb
qqsvvxuuuubcccccccdddfffdddcccccccb
qqvq.v.xrruuuuubbbbbbbbbbbbbbbuuuuu
qqsq.vv..pxrrruuuuuuuuuuuuuuuurrrrr
--
zzz................................
zzzz...............................
fzzoo..............................
lollll.............................
llllil.............................
llllil.............................
zzllilf............................
zzzii.fff..........................
zzzz...ff..........................
zzz......ff........................
zzz........ff......................
zzz........fffxxxxxxxxxxxxxxxx.....
zzz....xxxxxxfffbbbbbbbbbbbbbbxxxxx
zzs..xxuaabbbbcfffdddddddddcccbbbbb
zqs..xuabbbccccdffdddddddddjddccccb
qqsvvxuuuubcccccccffddddddccgccjccb
qqvq.v.xrruuuuubbbbbffbbbbbbbbuuuuu
qqsq.vv..pxrrruuuuuuuuuuuuuuuurrrrr
--
zzz................................
zzzz...............................
fzzoo..............................
lollll.............................
llllil.............................
llllil.............................
zzllilf............................
zzziifff...........................
zzzz..fff..........................
zzz....fff.........................
zzz.....fff........................
zzz.......ff..xxxxxxxxxxxxxxxx.....
zzz....xxxxffxabbbbbbbbabbbbbbxxxxx
zzs..xxuaabbfffccddddddddddcccgbbbb
zqs..xuabbbccffdddddddddddddddccccb
qqsvvxuuuubccjfffcdddddddddcccccccb
qqvq.v.xrruuuuubffbbbbbbbbbbbbuuuuu
qqsq.vv..pxrrruuuuuuuuuuuuuuuurrrrr
SPRITE_END
    )"
    # flames: 6 frames of 33x5 cells, every 1 tick(s), rand
    ui_add_psprite 21 30 1 rand "$(cat <<'SPRITE_END'
.rqqqqqqqqprqqrqqqqqrqqqqqqqpqqrv
.rqpqpqqqqqqqmrqqqqqqrqqqqqqqqrpv
.rqqqqrqqqqqqmqrrqrqqqqqqqqqrqqp.
..pqqrqqqmqqqmrqqqqqrqqqqqqpqq...
..rqpqqqqmmqmmrrmmqqrrpqqqqqqq...
...rpmqrqnmqmnqqmnqqqqqqqqrqp....
..m..nmqpnmqmnqqmnqqrqqqmqp......
..m..nmrnnnmnnnmnnmqqrqqmm..m....
emmemnnmnnnmnnnmnnmemmemnmemmmeee
mnnmmnnmnnnmnnnmnnmmnmmnnnmmnmeee
--
.rqqqqqqqqprqqrqqqqqrqqqqqqqpqqrv
.rqpqpqqqqqqqqrqqqqqqrqqqqqqqqrpv
.rqqqqrqqqqqqpqrrqrqqqqqqqqqrqqp.
..pqqrqqqqqqqmrqqqqqrqqqqqqpqq...
..rqpqqqqmmqmmrrmmqqrrpqqqqqqq...
...rpmqrqnmqmnqqmnqqqqqqqqrqp....
..m..nmqpnmqmnqqmnqqrqqqmqp..m...
..m..nmrnnnmnnnmnnmqqrqqmmm.mm...
emmemnnmnnnmnnnmnnmemmemnmemmmeee
mnnmmnnmnnnmnnnmnnmmnmmnnnmmnmeee
--
.rqqqqqqqqprqqrqqqqqrqqqqqqqpqqrv
.rqpqpqqqqqqqqrqqqqqqrqqqqqqqqrpv
.rqqqqrqqqqqqmqrrqrqqqqqqqqqrqqp.
..pqqrqqqqqqqmrqqqqqrqqqqqqpqq...
..rqpqqqqmmqmmrrmmqqrrpqqqqqqq...
...rpmqrqnmqmnqqmnqqqqqqqqrqp....
..m..nmqpnmqmnqqmnqqrqqqmqp......
..m..nmrnnnmnnnmnnmqqrqqmmm.m....
emmemnnmnnnmnnnmnnmemmemnmemmmeee
mnnmmnnmnnnmnnnmnnmmnmmnnnmmnmeee
--
.rqqqqqqqqprqqrqqqqqrqqqqqqqpqqrv
.rqpqpqqqqqqqqrqqqqqqrqqqqqqqqrpv
.rqqqqrqqqqqqmqrrqrqqqqqqqqqrqqp.
..pqqrqqqqqqqmrqqqqqrqqqqqqpqq...
..rqpqqqqmmqmmrrmmqqrrpqqqqqqq...
...rpmqrqnmqmnqqmnqqqqqqqqrqp....
..m..nmqpnmqmnqqmnqqrqqqmqp......
..m..nmrnnnmnnnmnnmqqrqqmm..m....
emmemnnmnnnmnnnmnnmemmemnmemmmeee
mnnmmnnmnnnmnnnmnnmmnmmnnnmmnmeee
--
.rqqqqqqqqprqqrqqqqqrqqqqqqqpqqrv
.rqpqpqqqmqqqmrqqqqqqrqqqqqqqqrpv
.rqqqqrqqmqqqmqrrqrqqqqqqqqqrqqp.
..pqqrqqqmqqqmrqqqqqrqqqqqqpqq...
..rqpqqqqmmqmmrrmmqqrrpqqqqqqq...
...rpmqrqnmqmnqqmnqqqqqqqqrqp....
..m..nmqpnmqmnqqmnqqrqqqmqp..m...
..m..nmrnnnmnnnmnnmqqrqqmm..mm...
emmemnnmnnnmnnnmnnmemmemnmemmmeee
mnnmmnnmnnnmnnnmnnmmnmmnnnmmnmeee
--
.rqqqqqqqqprqqrqqqqqrqqqqqqqpqqrv
.rqpqpqqqmqqqmrqqqqqqrqqqqqqqqrpv
.rqqqqrqqmqqqmqrrqrqqqqqqqqqrqqp.
..pqqrqqqmqqqmrqqqqqrqqqqqqpqq...
..rqpqqqqmmqmmrrmmqqrrpqqqqqqq...
...rpmqrqnmqmnqqmnqqqqqqqqrqp....
..m..nmqpnmqmnqqmnqqrqqqmqp......
..m..nmrnnnmnnnmnnmqqrqqmm..m....
emmemnnmnnnmnnnmnnmemmemnmemmmeee
mnnmmnnmnnnmnnnmnnmmnmmnnnmmnmeee
SPRITE_END
    )" 0
    # smoke / sparks: scene-row scene-col drift height kind
    SC_SOURCES=("15 37 -1 99 gsmoke" "15 41 -1 99 gsmoke" "15 46 0 99 gsmoke" "15 50 1 99 gsmoke" "15 55 1 99 gsmoke" "15 46 0 6 spark")
}

scene_pixsides() {
    SC_KIND=pix SC_W=44 SC_H=18
    ui_set_palette "a28 b35 c41 d47 e52 f94 g137 h178 i180 j202 k220 l223 m233 n235 o237 p239 q241 r243 s245 t247 u249 v253 w255"
    # the picture: 2 rows of the text below = 1 row of the terminal; a letter is a colour (see the palette above), . = nothing
    SC_PIX=$(cat <<'EOF'
............................................
..........qqqq..............................
.........qoqooo.............................
.........qooomqo............................
........qpooooqqq...........................
........qooooonqm...........................
.....f.qnnnnhhnq............................
.....mffooooooooqq..........................
....qqqffqqqqqqqqqq.........................
........ffvviiiii...........................
........vvfviiiiil..........................
........vvvffiiiil..........................
........vvvvffiww...........................
.......tvvvvwffwww..........................
.......tvvvvnwnfwwl.........................
.......tvvvnoooniiii........................
......mnvvnnoooiiiii........................
......mntvnooooowiii........................
......nnnnnooooqwwgff.......................
.....mnnnnnoomwwww...f......................
.....mnnnnnnnuwwww....ff..uuuuuuuuuu........
.....nnnnnnnnnwwww...uuffabbbbbbbbbbuuuuu...
.....nnnnnnnnnuwwp.urbbcffcddddddddcccbbau..
....mnnnnnnnnnnwnpsurrbcccfcddddddccccbrrrs.
....mnnnnnnnnnnnnpnsuourrrrrrrrrrrrrrrroonss
....nnnnnnnnnnnnps.snonnonooooooooooonnnsn.s
....nnnnnnnnnnnnps.snnonnnnnnnnnnnnnnnnnsn.s
...mnnnnnnnnnnnnpsssonnnnnnnnnomnnnnnnonnssn
...mnnnnnnnnnnnnp.snonnnnnnnnonnnnnnnnnnosn.
...nnnnnnnnnnnnnp....nnnnnnnnnonnnnnnnmnm...
...nnnnnnnnnnnnnp....onnnnjnjonjnonnnnnn....
..mnnnnnnnnnnnnnp.....ojnnknknnknnnnnom.....
..mnnnnnnnnnnnnnp....j.kjjknkjjknnnnjm......
..nnnnnnnnnnnnnnp..ejjjkkkkjkkkkjjjjkejjeeee
..nnnnnnnnnnnnnnp..ekkjkkkkjkkkkjkjkkjkjeeee
..nnnnnnnnnnnnnnp..ekkekekkekekkekekkekkeeee
EOF
)
    # stir: 6 frames of 23x6 cells, every 2 tick(s), seq
    ui_add_psprite 7 16 2 seq "$(cat <<'SPRITE_END'
wwl....................
iiii...................
iiii...................
wiii...................
wwgff..................
ww...f.................
ww....ff..uuuuuuuuuu...
ww...uuffabbabbbbbbbuuu
wp.urbbcffcddddddddcccb
npsurrbcccfcddddddccbcb
npnsuourrrrrrrrrrrrrrrr
ps.snonnonooooooooooonn
--
wwl....................
iiii...................
iiii...................
wiiif..................
wwg.ff.................
ww....ff...............
ww......ffuuuuuuuuuu...
ww...uuuuffabbbbbbbbuuu
wp.urbbcbcdfdddddddcccb
npsurrbcccccddddddccccb
npnsuourrrrrrrrrrrrrrrr
ps.snonnonooooooooooonn
--
wwl....................
iiii...................
iiii...................
wiiif..................
wwg..ff................
ww.....ff..............
ww.......ffuuuuuuuuu...
ww...uuuuabffabbbbbbuuu
wp.urbbcbcdddffddddcccb
npsurrbccccccdddddccccb
npnsuourrrrrrrrrrrrrrrr
ps.snonnonooooooooooonn
--
wwl....................
iiii...................
iiii...................
wiiif..................
wwg..ff................
ww.....f...............
ww.......fuuuuuuuuuu...
ww...uuuuaffabbbbbbbuuu
wp.urbbcccddffdddddcccb
npsurrbcccccddffddccccb
npnsuourrrrrrrrrrrrrrrr
ps.snonnonooooooooooonn
--
wwl....................
iiii...................
iiii...................
wiii...................
wwg.ff.................
ww....f................
ww.....ff.uuuuuuuuuu...
ww...uuuafabbbbbbbbbuuu
wp.urbbcccffddddddccccb
npsurrbcccccfddddcccccb
npnsuourrrrrrfrrrrrrrrr
ps.snonnonooooooooooonn
--
wwl....................
iiii...................
iiii...................
wiii...................
wwg.f..................
ww...f.................
ww....ff..uuuuuuuuuu...
ww...uuffabbbbbabbbbuuu
wp.urbbcffdddddddddcccb
npsurrbccffcddddddccccb
npnsuourrrrfrrrrrrrrrrr
ps.snonnonooooooooooonn
SPRITE_END
    )"
    # flames: 6 frames of 22x3 cells, every 1 tick(s), rand
    ui_add_psprite 14 20 1 rand "$(cat <<'SPRITE_END'
onnnnnnnnonnnnnnnnnnos
.nnnnnnnnnonnnnnnnmnm.
.onjnnjnjonjnonnnnnn..
..ojnnknknnknnnnnom...
.j.kjjknkjjknnnnjm....
jjjkkkkjkkkkjjjjkejjee
--
onnnnnnnnonnnnnnnnnnos
.nnnnnnnnnonnnnnnnmnm.
.onjnnnnjonnnonnnnnn..
..ojnnknknnknnnnnom...
.j.kjjknkjjknnnnjj.j..
jjjkkkkjkkkkjjjjkejjee
--
onnnnnnnnonnnnnnnnnnos
.nnnnnnnnnonnnnnnnmnm.
.onjnnnnjonjnonnnnnn..
..ojnnknknnknnnnnom...
.j.kjjknkjjknnnnjj....
jjjkkkkjkkkkjjjjkejjee
--
onnnnnnnnonnnnnnnnnnos
.nnnnnnnnnonnnnnnnmnm.
.onjnnnnjonjnonnnnnn..
..ojnnknknnknnnnnom...
.j.kjjknkjjknnnnjm....
jjjkkkkjkkkkjjjjkejjee
--
onnnnnnnnonnnnnnnnnnos
.nnnnnnnnnonnnnnnnmnm.
.onnnnjnjonjnonnnnnn..
..ojnnknknnknnnnnom...
.j.kjjknkjjknnnnjm.j..
jjjkkkkjkkkkjjjjkejjee
--
onnnnnnnnonnnnnnnnnnos
.nnnnnnnnnonnnnnnnmnm.
.onnnnjnjonjnonnnnnn..
..ojnnknknnknnnnnom...
.j.kjjknkjjknnnnjm....
jjjkkkkjkkkkjjjjkejjee
SPRITE_END
    )" 0
    # smoke / sparks: scene-row scene-col drift height kind
    SC_SOURCES=("10 24 -1 99 gsmoke" "10 28 -1 99 gsmoke" "10 30 0 99 gsmoke" "10 34 1 99 gsmoke" "10 36 1 99 gsmoke" "10 30 0 4 spark")
}

scene_pixt2() {
    SC_KIND=pix SC_W=32 SC_H=13
    ui_set_palette "a28 b35 c41 d47 e52 f94 g137 h180 i202 j220 k223 l233 m235 n237 o239 p241 q243 r245 s249 t253 u255"
    # the picture: 2 rows of the text below = 1 row of the terminal; a letter is a colour (see the palette above), . = nothing
    SC_PIX=$(cat <<'EOF'
................................
.......pppp.....................
.......onnnp....................
......pnnnmp....................
...f..mnnnm.....................
....ffnnnnnn....................
....pffpthhhpp..................
......tfthhhh...................
......ttfhhhk...................
......tttfhuu...................
......tttuffuu..................
.....ltmmnnhhhh.................
.....mtmlnnughh.................
....lmmmnnnuugff................
....mmmmlnuuu..ff...............
....mmmmmmuuu...sfsssssssssss...
...lmmmmmmmum.sbbcfcdddddcccbbq.
...mmmmmmmmmorsqqqbbccccccbqqqnr
...mmmmmmmmmo.r.mnnqqqnqqqnmmr.r
...mmmmmmmmmr.rnmmmmmmmmmmmmmm.r
...mmmmmmmmmormmmmmmmmmmmmmmmnrm
..mmmmmmmmmmo..mmmmmmmmmmmmmmm..
..mmmmmmmmmmo...mmmmmiimmmmmm...
..mmmmmmmmmmo....imjijjmmmil....
..mmmmmmmmmmo.eiijijjjjiiijiieee
..mmmmmmmmmm..ejjjjjjjjjjjjjjeee
EOF
)
    # stir: 6 frames of 17x5 cells, every 2 tick(s), seq
    ui_add_psprite 5 12 2 seq "$(cat <<'SPRITE_END'
uu...............
hhh..............
ghh..............
ugff.............
u..ff............
u...sfsssssssssss
m.sbbcfcdddddcccb
orsqqqqbcbccbcbqq
o.r.mnnqqqnqqqnmm
r.rnmmmmmmmmmmmmm
--
uu...............
hhh..............
ghh..............
ug.f.............
u...ff...........
u...ssffsssssssss
m.sbbcccfddddcccb
orsqqqbccccccbbqq
o.r.mnnqqqnqqqnmm
r.rnmmmmmmmmmmmmm
--
uu...............
hhh..............
ghh..............
ug.ff............
u................
u...sssffssssssss
m.sbbcccdddddcccb
orsqqqqbcccbccbqq
o.r.mnnqqqnqqqnmm
r.rnmmmmmmmmmmmmm
--
uu...............
hhh..............
ghh..............
ug.ff............
u................
u...ssafsssssssss
m.sbbcccdddddcccb
orsqqqbcccbcbcbqq
o.r.mnnqqqnqqqnmm
r.rnmmmmmmmmmmmmm
--
uu...............
hhh..............
ghh..............
ug.f.............
u...f............
u...ssfssssssssss
m.sbbccffddddcccb
orsqqqbcbfccccqqq
o.r.mnnqqnnqqqnmm
r.rnmmmmmmmmmmmmm
--
uu...............
hhh..............
ghh..............
ugff.............
u..ff............
u...sfsssssssssss
m.sbbcfcdddddcccb
orsqqqqfccccccbqq
o.r.mnnnqqnqqqnmm
r.rnmmmmmmmmmmmmm
SPRITE_END
    )"
    # flames: 6 frames of 17x3 cells, every 1 tick(s), rand
    ui_add_psprite 10 14 1 rand "$(cat <<'SPRITE_END'
mmmmmmmmmmmmmmmnr
.mmmmmmmnmmmmmmm.
..mmmmmiimmmmmm..
...imjijjmmmil...
eiijijjjjiiijiiee
ejjjjjjjjjjjjjjee
--
mmmmmmmmmmmmmmmnr
.mmmmmmmmmmmmmmm.
..mmmmmimmmmmmm..
...imjijjmmmimi..
eiijijjjjiiijiiee
ejjjjjjjjjjjjjjee
--
mmmmmmmmmmmmmmmnr
.mmmmmmmmmmmmmmm.
..mmmmmiimmmmmm..
...imjijjmmmim...
eiijijjjjiiijiiee
ejjjjjjjjjjjjjjee
--
mmmmmmmmmmmmmmmnr
.mmmmmmmmmmmmmmm.
..mmmmmiimmmmmm..
...imjijjmmmil...
eiijijjjjiiijiiee
ejjjjjjjjjjjjjjee
--
mmmmmmmmmmmmmmmnr
.mmmmmmmmmmmmmmm.
..mmmmmiimmmmmm..
...imjijjmmmili..
eiijijjjjiiijiiee
ejjjjjjjjjjjjjjee
--
mmmmmmmmmmmmmmmnr
.mmmmmmmmmmmmmmm.
..mmmmmiimmmmmm..
...imjijjmmmil...
eiijijjjjiiijiiee
ejjjjjjjjjjjjjjee
SPRITE_END
    )" 0
    # smoke / sparks: scene-row scene-col drift height kind
    SC_SOURCES=("7 18 -1 99 gsmoke" "7 20 -1 99 gsmoke" "7 22 0 99 gsmoke" "7 24 1 99 gsmoke" "7 27 1 99 gsmoke" "7 22 0 3 spark")
}

scene_pixt3() {
    SC_KIND=pix SC_W=22 SC_H=9
    ui_set_palette "a35 b41 c47 d52 e94 f178 g180 h202 i220 j233 k235 l237 m239 n241 o243 p245 q249 r253 s255"
    # the picture: 2 rows of the text below = 1 row of the terminal; a letter is a colour (see the palette above), . = nothing
    SC_PIX=$(cat <<'EOF'
......................
.....lll..............
....mlln..............
..eekkfk..............
...nerggn.............
....reggg.............
....rress.............
....rrlesg............
...krkllgg............
...kkklss.e...........
...kkkkss..eqqqqqqq...
..kkkkkskqoaebcccbbao.
..kkkkkkkplkloololllpp
..kkkkkkkpkkkkkkkkkkkp
..kkkkkkm.kkkkkkkkkkj.
.kkkkkkkm..kkkhhkkkk..
.kkkkkkkm.hihiiihkhhd.
.kkkkkkk.diiiiiiiiiidd
EOF
)
    # stir: 6 frames of 12x4 cells, every 2 tick(s), seq
    ui_add_psprite 3 8 2 seq "$(cat <<'SPRITE_END'
s...........
sg..........
gg..........
s.e.........
s..eqqqqqqq.
kqoaebcccbaa
kplkloololll
kpkkkkkkkkkk
--
s...........
sg..........
gg..........
s...........
s..qeeqqqqq.
kqoabbcccbba
kplkloololll
kpkkkkkkkkkk
--
s...........
sg..........
gg..........
s...........
s...qeqqqqq.
kqoabbcccbba
kplkloololll
kpkkkkkkkkkk
--
s...........
sg..........
gg..........
s...........
s...eeqqqqq.
kqoabbcccbba
kplkloololll
kpkkkkkkkkkk
--
s...........
sg..........
gg..........
s...........
s..qeqqqqqq.
kqoabecccbba
kplklollolll
kpkkkkkkkkkk
--
s...........
sg..........
gg..........
s.e.........
s..eqqqqqqq.
kqoaeccccbba
kplkllololll
kpkkkkkkkkkk
SPRITE_END
    )"
    # flames: 6 frames of 11x2 cells, every 1 tick(s), rand
    ui_add_psprite 7 10 1 rand "$(cat <<'SPRITE_END'
kkkkkkkkkkj
.hkkhhkkkk.
hihiiihkhhd
iiiiiiiiiid
--
kkkkkkkkkkj
.hkkhhkkkk.
hihiiihkhhd
iiiiiiiiiid
--
kkkkkkkkkkj
.hkkhhkkkk.
hihiiihkhhd
iiiiiiiiiid
--
kkkkkkkkkkj
.hkkhhkkkk.
hihiiihkhhd
iiiiiiiiiid
--
kkkkkkkkkkj
.kkkhhkkkk.
hihiiihkhhd
iiiiiiiiiid
--
kkkkkkkkkkj
.kkkhhkkkk.
hihiiihkhhd
iiiiiiiiiid
SPRITE_END
    )" 0
    # smoke / sparks: scene-row scene-col drift height kind
    SC_SOURCES=("5 12 -1 99 gsmoke" "5 14 -1 99 gsmoke" "5 15 0 99 gsmoke" "5 17 1 99 gsmoke" "5 18 1 99 gsmoke" "5 15 0 2 spark")
}

# --demo: the same screen with made-up tasks, so you can watch Gandalf without installing anything
DEMO_TASKS=("Updating package lists" "Upgrading installed packages" "Google Chrome" "Brave Browser" "Tor"
            "Discord" "Telegram Desktop" "Obsidian Markdown editor" "Sublime Text" "Terminator terminal"
            "LibreOffice" "Flameshot" "SecLists" "Go" "assetfinder" "QBITorrent")
demo_setup() {
    local label i
    for label in "${DEMO_TASKS[@]}"; do
        next_task "$label"
        log_warning "Installing $label..."
        for i in 1 2 3 4; do
            printf 'Reading package lists... %d%%\n' $(( i * 25 ))
            sleep "${DEMO_DELAY:-0.4}"
        done
        log_success "$label: done!"
    done
}

# ----------------------------------------------------------------------------
# Summary, Ctrl+C handling and start-up checks
# ----------------------------------------------------------------------------

print_summary() {
    local step skipped
    echo
    if (( ${#FAILED_STEPS[@]} > 0 )); then
        printf '\e[91m%s\e[0m\n' "${#FAILED_STEPS[@]} step(s) failed even after $MAX_ATTEMPTS attempts:"
        for step in "${FAILED_STEPS[@]}"; do
            printf '\e[91m  - %s\e[0m\n' "$step"
        done
        printf '\e[91m%s\e[0m\n' "Details are in $ERROR_LOG"
    elif (( INTERRUPTED == 0 )); then
        log_success "All steps finished successfully!"
    fi
    if (( ${#RECOVERED_STEPS[@]} > 0 )); then
        log_warning "${#RECOVERED_STEPS[@]} step(s) failed at first but worked on the second attempt:"
        for step in "${RECOVERED_STEPS[@]}"; do
            log_warning "  - $step"
        done
    fi
    if (( ${#SKIPPED_APPS[@]} > 0 )); then
        printf -v skipped '%s, ' "${SKIPPED_APPS[@]}"
        log_warning "${#SKIPPED_APPS[@]} app(s) were already installed and skipped: ${skipped%, }"
    fi
    if (( UI_ACTIVE )); then
        log_warning "Everything the commands printed is saved in $OUTPUT_LOG"
    fi
    write_log INFO "Finished: ${#FAILED_STEPS[@]} step(s) failed, ${#RECOVERED_STEPS[@]} step(s) recovered on retry, ${#SKIPPED_APPS[@]} app(s) skipped (already installed)"
}

# Stop cleanly on Ctrl+C / kill instead of treating it as a failed step
on_interrupt() {
    INTERRUPTED=1
    echo
    log_error "Interrupted by the user${CURRENT_STEP:+ during: $CURRENT_STEP}"
    print_summary
    exit "$1"
}

# Stop right away if the script cannot do its job, instead of failing every step twice
preflight_checks() {
    if ! command -v apt > /dev/null 2>&1; then
        log_error "apt was not found. This script only supports Debian-based systems (Kali, Ubuntu, Debian...)."
        return 1
    fi
    if ! command -v sudo > /dev/null 2>&1; then
        log_error "sudo was not found. Please install sudo and run the script again."
        return 1
    fi
    if [[ $EUID -ne 0 ]]; then
        log_warning "Checking sudo access..."
        if ! sudo -v; then
            log_error "Could not get sudo access, nothing was installed."
            return 1
        fi
    fi
}

# ----------------------------------------------------------------------------
# Steps that need more than one command
# ----------------------------------------------------------------------------

add_brave_repo() {
    echo "deb [signed-by=$BRAVE_KEYRING] https://brave-browser-apt-release.s3.brave.com/ stable main" \
        | sudo tee /etc/apt/sources.list.d/brave-browser-release.list > /dev/null
}

install_brave() {
    # curl is needed to download the signing key
    command -v curl > /dev/null 2>&1 || apt_install "curl" curl || return 1

    if ! run_step "Downloading the Brave signing key" \
            sudo curl -fsSLo "$BRAVE_KEYRING" https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg; then
        sudo rm -f "$BRAVE_KEYRING"  # don't leave a broken key behind
        log_warning "Skipping Brave Browser because its signing key could not be downloaded."
        return 1
    fi

    run_step "Adding the Brave apt repository" add_brave_repo || return 1
    # A failed update is not fatal here, the install below may still work
    run_step "Updating package lists for Brave" sudo_apt update
    apt_install "Brave Browser" brave-browser
}

# Download and extract in one step, so a broken download is fetched again on retry
fetch_telegram() {
    wget "${WGET_OPTS[@]}" "https://telegram.org/dl/desktop/linux" -O telegram.tar.xz && tar -xf telegram.tar.xz
}

install_telegram() {
    if ! run_step "Downloading and extracting Telegram Desktop" fetch_telegram; then
        rm -f telegram.tar.xz  # don't leave a partial download behind
        return 1
    fi
}

unpack_rockyou() {
    if [[ -f "${ROCKYOU_GZ%.gz}" ]]; then
        log_warning "rockyou.txt is already unpacked."
        return 0
    fi
    sudo gunzip "$ROCKYOU_GZ"
}

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------
trap 'on_interrupt 130' INT
trap 'on_interrupt 143' TERM
trap ui_stop EXIT                  # puts the screen back, whatever way the script ends
trap 'exit 141' PIPE

if (( DEMO )); then
    TOTAL_TASKS=${#DEMO_TASKS[@]}
    ui_start
    demo_setup
    ui_finish
    print_summary
    exit 0
fi

preflight_checks || exit 1

# The progress bar has one step per "next_task" line below (they are counted here)
TOTAL_TASKS=$(grep -c '^next_task ' "${BASH_SOURCE[0]}" 2> /dev/null)
(( TOTAL_TASKS > 0 )) || TOTAL_TASKS=1
ui_start

# Update and upgrade the system
log_warning "Updating and upgrading the system..."
next_task "Updating package lists"
run_step "Updating package lists" sudo_apt update
next_task "Upgrading installed packages"
run_step -r fix_broken_deps "Upgrading installed packages" sudo_apt upgrade -y

# Every app below is skipped (no download, no install) if it is already installed:
#   skip_if_installed "App name" <apt package or command name>... || <install steps>



# Download and install Google Chrome
next_task "Google Chrome"
skip_if_installed "Google Chrome" google-chrome-stable google-chrome ||
    install_deb_from_url "Google Chrome" \
        "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
        google-chrome-stable_current_amd64.deb cleanup

# Launch Google Chrome
#log_warning "Launching Google Chrome..."
#google-chrome



# Install Brave browser
next_task "Brave Browser"
skip_if_installed "Brave Browser" brave-browser || install_brave

# Launch Brave browser
#log_warning "Launching Brave browser..."
#brave-browser



# Install Tor and the Tor Browser launcher (checked separately, either one can be missing)
next_task "Tor"
skip_if_installed "Tor" tor || apt_install "Tor" tor
next_task "Tor Browser launcher"
skip_if_installed "Tor Browser launcher" torbrowser-launcher || apt_install "Tor Browser launcher" torbrowser-launcher



# Download and install Discord
next_task "Discord"
skip_if_installed "Discord" discord ||
    install_deb_from_url "Discord" \
        "https://discord.com/api/download/stable?platform=linux&format=deb" \
        discord.deb



# Download and extract Telegram Desktop (installed from apt, or extracted next to the script)
next_task "Telegram Desktop"
skip_if_installed "Telegram Desktop" telegram-desktop "$PWD/Telegram/Telegram" || install_telegram




# Download and install Obsidian Markdown editor
next_task "Obsidian Markdown editor"
skip_if_installed "Obsidian Markdown editor" obsidian ||
    install_deb_from_url "Obsidian Markdown editor" \
        "https://github.com/obsidianmd/obsidian-releases/releases/download/v1.4.5/obsidian_1.4.5_amd64.deb" \
        obsidian.deb



# Download and install Sublime Text 3 (any installed Sublime Text counts, so Sublime Text 4 is never downgraded)
next_task "Sublime Text"
skip_if_installed "Sublime Text" sublime-text subl ||
    install_deb_from_url "Sublime Text 3" \
        "https://download.sublimetext.com/sublime-text_build-3211_amd64.deb" \
        sublime-text.deb



# Download and install Terminator
next_task "Terminator terminal"
skip_if_installed "Terminator terminal" terminator || apt_install "Terminator terminal" terminator

# Installing Libreoffice
next_task "LibreOffice"
skip_if_installed "LibreOffice" libreoffice soffice || apt_install "LibreOffice" libreoffice



# Download and install Flameshot
next_task "Flameshot"
skip_if_installed "Flameshot" flameshot || apt_install "screenshot tool Flameshot" flameshot



# Unpacking rockyou.txt
next_task "rockyou.txt"
run_step "Unpacking rockyou.txt" unpack_rockyou



# Installing Seclists
next_task "SecLists"
skip_if_installed "SecLists" seclists "$SECLISTS_DIR" || apt_install "SecLists" seclists



# Installing Go (a Go that was installed some other way counts too)
next_task "Go"
skip_if_installed "Go" golang-go go || apt_install "Go" golang-go



# Downloading and installing assetfinder (needs Go; also found in GOBIN / GOPATH)
next_task "assetfinder"
if command -v go > /dev/null 2>&1; then
    skip_if_installed "assetfinder" assetfinder "$(go_bin_dir)/assetfinder" ||
        run_step "Downloading and installing assetfinder" go install github.com/tomnomnom/assetfinder@latest
else
    log_warning "Skipping assetfinder because Go is not available."
fi




# Downloading and installing QBITorrent
next_task "QBITorrent"
skip_if_installed "QBITorrent" qbittorrent || apt_install "QBITorrent" qbittorrent




# Download and install Yandex Browser
next_task "Yandex Browser"
skip_if_installed "Yandex Browser" yandex-browser-stable yandex-browser ||
    install_deb_from_url "Yandex Browser" \
        "https://browser.yandex.com/download?os=linux&package=deb" \
        yandex-browser.deb cleanup



ui_finish
print_summary
if (( ${#FAILED_STEPS[@]} > 0 )); then
    exit 1
fi
exit 0
