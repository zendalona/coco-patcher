#!/usr/bin/env bash
# ==============================================================================
# Download and Install Hear2Read Module & Voices - Native Setup & Installer
# Features:
#   - Adaptive module detection (install full engine vs voice manager)
#   - Direct high-speed GitHub Releases CDN downloads for module and voices
#   - Voice deletion on uncheck from both system and user voice directories
#   - Empty selection confirmation (revert cleanly to system eSpeak)
#   - Continuous 2-second audio progress beacon for blind / Orca users
#   - Dynamic hear2read.conf and speechd.conf generation (no hardcoded languages)
#   - In-place module upgrade preserving all existing downloaded voices
#   - Seamless Orca screen reader refresh
# ==============================================================================

MODULE_VERSION="1.0.3"       # Version used to detect/track installed module version
GITHUB_RELEASE_TAG="v1.0.0"   # GitHub release tag where assets are hosted
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICES_DIR_SYS="/usr/share/hear2read/Voices"
VOICES_DIR_USER="$HOME/.local/share/hear2read/Voices"
MODULE_SYS="/usr/lib/speech-dispatcher-modules"
MODULE_USER="$HOME/.local/libexec/speech-dispatcher-modules"
CONF_SYS="/etc/speech-dispatcher/modules/hear2read.conf"
SPEECHD_CONF="/etc/speech-dispatcher/speechd.conf"
APP_DIR="$HOME/.local/share/hear2read"
DESKTOP_DIR="$HOME/.local/share/applications"

GITHUB_BUNDLE_URL="https://github.com/zendalona/hear2read-spd-module-assets/releases/download/${GITHUB_RELEASE_TAG}/hear2read-linux.tar.gz"
GITHUB_BUNDLE_FALLBACK="https://github.com/zendalona/hear2read-spd-module/releases/download/${GITHUB_RELEASE_TAG}/hear2read-linux.tar.gz"
GITHUB_VOICE_BASE="https://github.com/zendalona/hear2read-spd-module-assets/releases/download/${GITHUB_RELEASE_TAG}"

# Automatically clean up any stale extraction directory or temporary files from previous runs
rm -rf /tmp/hear2read_extract /tmp/hear2read_voice_selector.py /tmp/hear2read_progress_ui.py /tmp/hear2read.conf /tmp/hear2read-linux.tar.gz 2>/dev/null || true

# Auto-install any missing prerequisites on the target system
check_and_install_prereqs() {
    local missing=()
    command -v zenity >/dev/null 2>&1 || missing+=("zenity")
    command -v spd-say >/dev/null 2>&1 || missing+=("speech-dispatcher")

    # Check if espeak-ng, espeak or libespeak-ng is available
    local espeak_present=false
    if command -v espeak-ng >/dev/null 2>&1 || command -v espeak >/dev/null 2>&1; then
        espeak_present=true
    elif command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' espeak-ng 2>/dev/null | grep -q "install ok installed"; then
        espeak_present=true
    elif command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' libespeak-ng1 2>/dev/null | grep -q "install ok installed"; then
        espeak_present=true
    fi
    if [ "$espeak_present" = false ]; then
        missing+=("espeak-ng")
    fi

    # Check for espeak phonetic dictionaries
    local espeak_data_present=false
    for d in "/usr/lib/x86_64-linux-gnu/espeak-ng-data" "/usr/share/espeak-ng-data" "/usr/lib/espeak-ng-data" "/usr/local/share/espeak-ng-data" "/usr/lib/x86_64-linux-gnu/espeak-data" "/usr/share/espeak-data"; do
        if [ -d "$d" ]; then
            espeak_data_present=true
            break
        fi
    done
    if [ "$espeak_data_present" = false ]; then
        if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' espeak-ng-data 2>/dev/null | grep -q "install ok installed"; then
            espeak_data_present=true
        fi
    fi
    if [ "$espeak_data_present" = false ]; then
        missing+=("espeak-ng-data")
    fi

    command -v wget >/dev/null 2>&1 || missing+=("wget")
    command -v tar >/dev/null 2>&1 || missing+=("tar")
    command -v xz >/dev/null 2>&1 || missing+=("xz-utils")
    
    # Check for GTK3 Python bindings
    if ! python3 -c "import gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk" 2>/dev/null; then
        missing+=("python3-gi" "gir1.2-gtk-3.0")
    fi

    # Check for canberra audio feedback utility
    if ! command -v canberra-gtk-play >/dev/null 2>&1; then
        missing+=("libcanberra-gtk3-module" "canberra-gtk-play")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing system packages detected: ${missing[*]}"
        if [ "$EUID" -eq 0 ]; then
            echo "Installing automatically via package manager..."
            apt-get update -qq 2>/dev/null || true
            apt-get install -y "${missing[@]}" 2>/dev/null || true
        elif sudo -n true 2>/dev/null; then
            echo "Installing automatically via package manager..."
            sudo -n apt-get update -qq 2>/dev/null || true
            sudo -n apt-get install -y "${missing[@]}" 2>/dev/null || true
        else
            echo "Note: Root privileges not cached; skipping automatic apt-get installation."
        fi
    fi
}

check_and_install_prereqs

# Ensure required local config directory exists for user preferences
mkdir -p "$HOME/.config/hear2read"

# Language definitions for all 14 Hear2Read Indic languages
declare -A LANG_NAMES=(
    ["as"]="Assamese (অসমীয়া)"
    ["bn"]="Bengali (বাংলা)"
    ["gu"]="Gujarati (ગુજરાતી)"
    ["hi"]="Hindi (हिन्दी)"
    ["kn"]="Kannada (ಕನ್ನಡ)"
    ["ml"]="Malayalam (മലയാളം)"
    ["mr"]="Marathi (मराठी)"
    ["ne"]="Nepali (नेपाली)"
    ["or"]="Odia (ଓଡ଼ିଆ)"
    ["pa"]="Punjabi (ਪੰਜਾਬੀ)"
    ["sa"]="Sanskrit (संस्कृतम्)"
    ["si"]="Sinhala (සිංහල)"
    ["ta"]="Tamil (தமிழ்)"
    ["te"]="Telugu (తెలుగు)"
)

declare -A LANG_FILES=(
    ["as"]="as-v5-low.tar.xz"
    ["bn"]="bn-v5-low.tar.xz"
    ["gu"]="gu-v5-low.tar.xz"
    ["hi"]="hi-v5-tdilv2mono-1665val-med.tar.xz"
    ["kn"]="kn-v5-low.tar.xz"
    ["ml"]="ml-tdil-1729zha-low.tar.xz"
    ["mr"]="mr-v5-low.tar.xz"
    ["ne"]="ne-v5-low.tar.xz"
    ["or"]="or-v5-low.tar.xz"
    ["pa"]="pa-v5-low.tar.xz"
    ["sa"]="sa-v5-low.tar.xz"
    ["si"]="si-v5-low.tar.xz"
    ["ta"]="ta-v5-low.tar.xz"
    ["te"]="te-v5-low.tar.xz"
)

is_voice_installed() {
    local code="$1"
    for d in "$VOICES_DIR_SYS" "$VOICES_DIR_USER"; do
        if [ -d "$d" ]; then
            for f in "$d"/"$code"-*.onnx; do
                if [ -f "$f" ]; then return 0; fi
            done
        fi
    done
    return 1
}

is_module_installed() {
    if [ -x "$MODULE_SYS/sd_hear2read" ] || [ -x "$MODULE_USER/sd_hear2read" ] || [ -x "/usr/local/bin/sd_hear2read" ] || [ -x "$HOME/.local/bin/sd_hear2read" ]; then
        return 0
    fi
    return 1
}

get_installed_version() {
    local v=""
    for b in "$MODULE_USER/sd_hear2read" "$MODULE_SYS/sd_hear2read" "$HOME/.local/bin/sd_hear2read" "/usr/local/bin/sd_hear2read"; do
        if [ -f "$b" ]; then
            if [ -x "$b" ]; then
                v=$(timeout 1s "$b" --version </dev/null 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?' | head -n 1 || true)
            fi
            if [ -z "$v" ] && command -v strings >/dev/null 2>&1; then
                v=$(strings "$b" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)?$' | head -n 1 || true)
            fi
            if [ -n "$v" ]; then break; fi
        fi
    done
    if [ -z "$v" ]; then
        if [ -f "$APP_DIR/version.txt" ]; then
            v=$(cat "$APP_DIR/version.txt" 2>/dev/null | tr -d '[:space:]')
        elif [ -f "/usr/share/hear2read/version.txt" ]; then
            v=$(cat "/usr/share/hear2read/version.txt" 2>/dev/null | tr -d '[:space:]')
        fi
    fi
    echo "$v"
}

# ==============================================================================
# STEP 1: PRESENT LANGUAGE CHECKLIST
# ==============================================================================
ORDER=("as" "bn" "gu" "hi" "kn" "ml" "mr" "ne" "or" "pa" "sa" "si" "ta" "te")

INITIAL_INSTALLED_CODES=()
for code in "${ORDER[@]}"; do
    if is_voice_installed "$code"; then
        INITIAL_INSTALLED_CODES+=("$code")
    fi
done

DIALOG_TITLE="Hear2Read Speech-Dispatcher Module"
DIALOG_HEADING="<b><big>Install and integrate Hear2Read Indic neural TTS module and voices.</big></b>"

if is_module_installed; then
    DIALOG_DESC="Hear2Read module is already installed.\n\nSelect languages you would like to add, or uncheck installed languages to remove them:"
    DIALOG_OK_LABEL="Apply Voice Changes"
else
    DIALOG_DESC="Install and integrate Hear2Read Indic neural TTS module and voices with local speech-dispatcher.\n\nSelect languages you would like to install:"
    DIALOG_OK_LABEL="Download & Install Hear2Read Module & Voices"
fi

VOICE_SEL_PY="$SCRIPT_DIR/voice_selector.py"
if [ ! -f "$VOICE_SEL_PY" ]; then
    if [ -f "$APP_DIR/voice_selector.py" ]; then
        VOICE_SEL_PY="$APP_DIR/voice_selector.py"
    else
        VOICE_SEL_PY="/tmp/hear2read_voice_selector.py"
        cat << 'VOICE_SEL_EOF' > "$VOICE_SEL_PY"
#!/usr/bin/env python3
import os, sys, gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

VOICES_DIR_SYS = "/usr/share/hear2read/Voices"
VOICES_DIR_USER = os.path.expanduser("~/.local/share/hear2read/Voices")

LANGUAGES = [
    {"code": "as", "name": "Assamese", "native": "অসমীয়া"},
    {"code": "bn", "name": "Bengali", "native": "বাংলা"},
    {"code": "gu", "name": "Gujarati", "native": "ગુજરાતી"},
    {"code": "hi", "name": "Hindi", "native": "हिन्दी"},
    {"code": "kn", "name": "Kannada", "native": "ಕನ್ನಡ"},
    {"code": "ml", "name": "Malayalam", "native": "മലയാളം"},
    {"code": "mr", "name": "Marathi", "native": "मराठी"},
    {"code": "ne", "name": "Nepali", "native": "नेपाली"},
    {"code": "or", "name": "Odia", "native": "ଓଡ଼ିଆ"},
    {"code": "pa", "name": "Punjabi", "native": "ਪੰਜਾਬੀ"},
    {"code": "sa", "name": "Sanskrit", "native": "संस्कृतम्"},
    {"code": "si", "name": "Sinhala", "native": "සිංහල"},
    {"code": "ta", "name": "Tamil", "native": "தமிழ்"},
    {"code": "te", "name": "Telugu", "native": "తెలుగు"}
]

def is_voice_installed(code):
    for d in [VOICES_DIR_SYS, VOICES_DIR_USER]:
        if os.path.isdir(d):
            for f in os.listdir(d):
                if f.startswith(f"{code}-") and f.endswith(".onnx"):
                    return True
    return False

def apply_accessible_css():
    css = b"""
    window {
        background-color: #242424;
        color: #ffffff;
    }
    *:focus {
        outline: 2px solid #f59e0b;
        outline-offset: 2px;
    }
    button.apply-btn {
        background-color: #15803d;
        color: #ffffff;
        font-weight: bold;
        border-radius: 6px;
        padding: 8px 18px;
        border: 1px solid #166534;
    }
    button.apply-btn:hover, button.apply-btn:focus {
        background-color: #16a34a;
    }
    button.help-btn {
        background-color: #0284c7;
        color: #ffffff;
        font-weight: bold;
        border-radius: 6px;
        padding: 8px 16px;
        border: 1px solid #0369a1;
    }
    button.help-btn:hover, button.help-btn:focus {
        background-color: #0ea5e9;
    }
    button.cancel-btn {
        background-color: #374151;
        color: #ffffff;
        font-weight: bold;
        border-radius: 6px;
        padding: 8px 18px;
        border: 1px solid #4b5563;
    }
    button.cancel-btn:hover, button.cancel-btn:focus {
        background-color: #4b5563;
    }
    checkbutton check {
        min-width: 20px;
        min-height: 20px;
    }
    label {
        color: #f9fafb;
    }
    """
    provider = Gtk.CssProvider()
    provider.load_from_data(css)
    screen = Gdk.Screen.get_default()
    if screen:
        Gtk.StyleContext.add_provider_for_screen(
            screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

class VoiceSelectorWindow(Gtk.Window):
    def __init__(self, title=None):
        installed_any = any(is_voice_installed(l["code"]) for l in LANGUAGES)
        default_title = "Hear2Read Speech-Dispatcher Module"
        win_title = title or default_title

        super().__init__(title=win_title)
        apply_accessible_css()
        self.set_default_size(620, 520)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_border_width(14)

        self.connect("key-press-event", self.on_key_press_event)
        self.checkboxes = {}
        self.selected_codes = []

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.add(main_box)

        lbl_heading = Gtk.Label()
        heading_text = "<b><big>Install and integrate Hear2Read Indic neural TTS module and voices.</big></b>"
        lbl_heading.set_markup(heading_text)
        lbl_heading.set_xalign(0.0)
        lbl_heading.set_yalign(0.5)
        main_box.pack_start(lbl_heading, False, False, 0)

        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scrolled.set_hexpand(True)
        scrolled.set_vexpand(True)
        main_box.pack_start(scrolled, True, True, 4)

        list_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        list_box.set_border_width(8)
        scrolled.add(list_box)

        first_chk = None
        for lang in LANGUAGES:
            code = lang["code"]
            is_inst = is_voice_installed(code)

            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)

            label_text = f"{lang['name']} ({lang['native']})"
            chk = Gtk.CheckButton(label=label_text)
            chk.set_active(is_inst)
            chk.set_hexpand(True)

            self.checkboxes[code] = chk
            row.pack_start(chk, True, True, 0)

            lbl_stat = Gtk.Label()
            lbl_stat.set_xalign(1.0)
            lbl_stat.set_yalign(0.5)
            if is_inst:
                lbl_stat.set_markup("<span color='#4caf50'><b>Installed</b></span>")
            else:
                lbl_stat.set_markup("<span color='#9ca3af'>Available</span>")
            row.pack_start(lbl_stat, False, False, 4)

            list_box.pack_start(row, False, False, 2)

            if first_chk is None:
                first_chk = chk

        bottom_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        bottom_box.set_margin_top(8)

        btn_help = Gtk.Button(label="Help")
        btn_help.get_style_context().add_class("help-btn")
        btn_help.connect("clicked", self.on_help_clicked)
        bottom_box.pack_start(btn_help, False, False, 0)

        spacer = Gtk.Box()
        bottom_box.pack_start(spacer, True, True, 0)

        btn_cancel = Gtk.Button(label="Cancel")
        btn_cancel.get_style_context().add_class("cancel-btn")
        btn_cancel.connect("clicked", self.on_cancel_clicked)
        bottom_box.pack_start(btn_cancel, False, False, 0)

        apply_label = "Apply Voice Changes" if installed_any else "Download & Install"
        btn_apply = Gtk.Button(label=apply_label)
        btn_apply.get_style_context().add_class("apply-btn")
        btn_apply.connect("clicked", self.on_apply_clicked)
        bottom_box.pack_start(btn_apply, False, False, 0)

        main_box.pack_start(bottom_box, False, False, 0)

        if first_chk:
            GLib.idle_add(first_chk.grab_focus)

    def on_key_press_event(self, widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.on_cancel_clicked(None)
            return True
        if event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            focus_widget = self.get_focus()
            if isinstance(focus_widget, Gtk.CheckButton):
                focus_widget.set_active(not focus_widget.get_active())
                return True
        return False

    def on_help_clicked(self, btn):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=Gtk.DialogFlags.MODAL,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK,
            text="Hear2Read Voice Selection Help"
        )
        dialog.format_secondary_text(
            "How to select and manage Hear2Read voices:\n\n"
            "• Navigate Languages: Use Up and Down arrow keys to navigate between languages.\n\n"
            "• Select / Unselect: Press Spacebar or Enter to check or uncheck any language.\n\n"
            "• Apply Changes: Use Tab to navigate to 'Apply Voice Changes' (or 'Download & Install') and press Enter or Spacebar to start downloading.\n\n"
            "• Installed Voices: Languages already installed are marked 'Installed' and checked by default. Unchecking an installed language removes its voice model to free disk space.\n\n"
            "• Internet Connection: An active internet connection is required to download new voice models."
        )
        dialog.run()
        dialog.destroy()

    def on_cancel_clicked(self, btn):
        sys.exit(1)

    def on_apply_clicked(self, btn):
        selected = []
        for code, chk in self.checkboxes.items():
            if chk.get_active():
                selected.append(code)

        if not selected:
            installed_any = any(is_voice_installed(l["code"]) for l in LANGUAGES)
            if installed_any:
                dialog = Gtk.MessageDialog(
                    transient_for=self,
                    flags=Gtk.DialogFlags.MODAL,
                    message_type=Gtk.MessageType.WARNING,
                    buttons=Gtk.ButtonsType.YES_NO,
                    text="Remove All Voices?"
                )
                dialog.format_secondary_text(
                    "You have unchecked all Indic voices.\n\n"
                    "Do you want to remove all Hear2Read Indic voices and revert system speech to default eSpeak?"
                )
                res = dialog.run()
                dialog.destroy()
                if res != Gtk.ResponseType.YES:
                    return
            else:
                dialog = Gtk.MessageDialog(
                    transient_for=self,
                    flags=Gtk.DialogFlags.MODAL,
                    message_type=Gtk.MessageType.WARNING,
                    buttons=Gtk.ButtonsType.OK,
                    text="No Voice Selected"
                )
                dialog.format_secondary_text("Please select at least one language voice to install.")
                dialog.run()
                dialog.destroy()
                return

        print(" ".join(selected))
        sys.exit(0)

def main():
    title = sys.argv[1] if len(sys.argv) > 1 else None
    app = VoiceSelectorWindow(title=title)
    app.connect("destroy", lambda w: sys.exit(1))
    app.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
VOICE_SEL_EOF
        chmod +x "$VOICE_SEL_PY"
    fi
fi

if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
    SELECTED_CODES=$(python3 "$VOICE_SEL_PY" "$DIALOG_TITLE")
    STATUS=$?
    if [ $STATUS -ne 0 ]; then
        echo "Setup cancelled by user."
        exit 0
    fi
else
    echo "Console mode: Selecting all Indic languages..."
    SELECTED_CODES="${ORDER[*]}"
fi

# Trim whitespace
SELECTED_CODES=$(echo "$SELECTED_CODES" | xargs)

# Detect unchecked/deleted voices and newly requested voices
DELETED_CODES=()
for init_c in "${INITIAL_INSTALLED_CODES[@]}"; do
    found=0
    for sel_c in $SELECTED_CODES; do
        if [ "$init_c" = "$sel_c" ]; then
            found=1
            break
        fi
    done
    if [ $found -eq 0 ]; then
        DELETED_CODES+=("$init_c")
    fi
done

TO_DOWNLOAD_CODES=()
for sel_c in $SELECTED_CODES; do
    is_inst=0
    for init_c in "${INITIAL_INSTALLED_CODES[@]}"; do
        if [ "$sel_c" = "$init_c" ]; then
            is_inst=1
            break
        fi
    done
    if [ $is_inst -eq 0 ]; then
        TO_DOWNLOAD_CODES+=("$sel_c")
    fi
done

IS_MOD_INSTALLED=0
is_module_installed && IS_MOD_INSTALLED=1

NUM_TO_DOWNLOAD=${#TO_DOWNLOAD_CODES[@]}
NUM_TO_DELETE=${#DELETED_CODES[@]}
NUM_INITIAL=${#INITIAL_INSTALLED_CODES[@]}

PROGRESS_TITLE="Hear2Read Speech-Dispatcher Module"

if [ "$IS_MOD_INSTALLED" -eq 0 ]; then
    if [ "$NUM_TO_DOWNLOAD" -gt 0 ]; then
        PROGRESS_SUBTITLE="Installing module and voice models..."
    else
        PROGRESS_SUBTITLE="Installing Hear2Read module..."
    fi
else
    if [ "$NUM_TO_DOWNLOAD" -gt 0 ] && [ "$NUM_TO_DELETE" -eq 0 ]; then
        PROGRESS_SUBTITLE="Adding new voice models..."
    elif [ "$NUM_TO_DOWNLOAD" -eq 0 ] && [ "$NUM_TO_DELETE" -gt 0 ]; then
        if [ "$NUM_TO_DELETE" -ge "$NUM_INITIAL" ] && [ "$NUM_INITIAL" -gt 0 ]; then
            PROGRESS_SUBTITLE="Removing all voice models..."
        else
            PROGRESS_SUBTITLE="Removing selected voice models..."
        fi
    elif [ "$NUM_TO_DOWNLOAD" -gt 0 ] && [ "$NUM_TO_DELETE" -gt 0 ]; then
        PROGRESS_SUBTITLE="Updating voice models (adding and removing)..."
    else
        PROGRESS_SUBTITLE="Verifying configuration and speech integration..."
    fi
fi

# ==============================================================================
# PREPARE GTK3 PROGRESS DIALOG (WITH SHOW/HIDE DETAILS & 2S BEACON)
# ==============================================================================
PROGRESS_PY="$SCRIPT_DIR/progress_ui.py"
if [ ! -f "$PROGRESS_PY" ]; then
    PROGRESS_PY="/tmp/hear2read_progress_ui.py"
    rm -f "$PROGRESS_PY"
    cat << 'PROGRESS_EOF' > "$PROGRESS_PY"
#!/usr/bin/env python3
import sys, os, time, subprocess, threading, gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib

class Hear2ReadProgressWindow(Gtk.Window):
    def __init__(self, title="Hear2Read Speech-Dispatcher Module", subtitle=None):
        super().__init__(title=title)
        self.set_default_size(580, 200)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_border_width(16)
        self.set_resizable(True)

        self.last_sound_time = 0.0
        self.sound_interval = 1.0
        self.is_completed = False
        self.has_error = False
        self.last_error_msg = ""
        self.last_announced_percent = -1
        self.ensure_beep_file()
        self.ticker_timer_id = GLib.timeout_add_seconds(2, self.on_periodic_ticker)

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(main_box)

        header_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        icon = Gtk.Image()
        theme = Gtk.IconTheme.get_default()
        for icon_name in ["preferences-desktop-accessibility", "audio-volume-high", "system-software-install", "dialog-information"]:
            if theme.has_icon(icon_name):
                icon.set_from_icon_name(icon_name, Gtk.IconSize.DIALOG)
                break
        header_box.pack_start(icon, False, False, 0)

        title_vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        title_label = Gtk.Label()
        title_label.set_markup(f"<b><big>{GLib.markup_escape_text(title)}</big></b>")
        title_label.set_xalign(0.0)
        title_vbox.pack_start(title_label, False, False, 0)

        self.sub_label = Gtk.Label()
        self.sub_label.set_text(subtitle or "Setting up synthesizer engine and voice models...")
        self.sub_label.set_xalign(0.0)
        title_vbox.pack_start(self.sub_label, False, False, 0)

        header_box.pack_start(title_vbox, True, True, 0)
        main_box.pack_start(header_box, False, False, 0)

        self.status_label = Gtk.Label()
        self.status_label.set_markup("<b>Step 1/6: Verifying core package and synthesizer engine...</b>")
        self.status_label.set_xalign(0.0)
        self.status_label.set_line_wrap(True)
        main_box.pack_start(self.status_label, False, False, 0)

        self.progress_bar = Gtk.ProgressBar()
        self.progress_bar.set_fraction(0.05)
        self.progress_bar.set_show_text(True)
        self.progress_bar.set_text("5%")
        main_box.pack_start(self.progress_bar, False, False, 0)

        # Button Box (Show Details button)
        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.details_btn = Gtk.Button(label="Show Details")
        self.details_btn.connect("clicked", self.toggle_details)
        btn_box.pack_start(self.details_btn, False, False, 0)
        main_box.pack_start(btn_box, False, False, 0)

        self.scrolled_window = Gtk.ScrolledWindow()
        self.scrolled_window.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.scrolled_window.set_shadow_type(Gtk.ShadowType.IN)
        self.scrolled_window.set_min_content_height(220)
        self.scrolled_window.set_visible(False)

        self.text_view = Gtk.TextView()
        self.text_view.set_editable(False)
        self.text_view.set_cursor_visible(False)
        self.text_view.set_wrap_mode(Gtk.WrapMode.CHAR)
        css = Gtk.CssProvider()
        css.load_from_data(b"textview text { font-family: monospace; font-size: 11px; }")
        self.text_view.get_style_context().add_provider(css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.text_buffer = self.text_view.get_buffer()
        self.scrolled_window.add(self.text_view)
        main_box.pack_start(self.scrolled_window, True, True, 0)

        self.connect("destroy", self.on_window_close)
        self.reader_thread = threading.Thread(target=self.read_stdin, daemon=True)
        self.reader_thread.start()

    def toggle_details(self, widget):
        visible = self.scrolled_window.get_visible()
        if visible:
            self.scrolled_window.set_visible(False)
            self.details_btn.set_label("Show Details")
            self.resize(580, 200)
        else:
            self.scrolled_window.set_visible(True)
            self.details_btn.set_label("Hide Details")
            self.resize(580, 450)
            self.scroll_to_end()

    def ensure_beep_file(self):
        self.beep_path = "/tmp/hear2read_beep.wav"
        if not os.path.exists(self.beep_path):
            try:
                import wave, math, struct
                with wave.open(self.beep_path, 'w') as f:
                    f.setnchannels(1)
                    f.setsampwidth(2)
                    f.setframerate(22050)
                    n = int(22050 * 0.07)
                    frames = [struct.pack('<h', int((1.0 - i/n) * 14000 * math.sin(2 * math.pi * 800 * i / 22050))) for i in range(n)]
                    f.writeframes(b''.join(frames))
            except Exception: pass

    def on_periodic_ticker(self):
        if self.is_completed:
            return False
        self.play_accessibility_sound(force=True)
        return True

    def play_accessibility_sound(self, force=False):
        now = time.time()
        if not force and (now - self.last_sound_time < self.sound_interval):
            return
        self.last_sound_time = now
        if hasattr(self, 'beep_path') and os.path.exists(self.beep_path):
            if os.path.exists("/usr/bin/paplay"):
                subprocess.Popen(["paplay", self.beep_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return
            elif os.path.exists("/usr/bin/aplay"):
                subprocess.Popen(["aplay", "-q", self.beep_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return
        if os.path.exists("/usr/bin/canberra-gtk-play"):
            subprocess.Popen(["canberra-gtk-play", "-i", "audio-volume-change", "-d", "Hear2Read Setup"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        try:
            sys.stdout.write('\a')
            sys.stdout.flush()
        except Exception: pass

    def play_complete_sound(self):
        if os.path.exists("/usr/bin/canberra-gtk-play"):
            try:
                subprocess.Popen(["canberra-gtk-play", "-i", "dialog-information", "-d", "Hear2Read Setup Complete"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return
            except Exception: pass
        self.play_accessibility_sound(force=True)

    def append_log(self, text):
        end_iter = self.text_buffer.get_end_iter()
        self.text_buffer.insert(end_iter, text + "\n")
        self.scroll_to_end()

    def scroll_to_end(self):
        end_mark = self.text_buffer.create_mark(None, self.text_buffer.get_end_iter(), False)
        self.text_view.scroll_to_mark(end_mark, 0.05, True, 0.0, 1.0)

    def speak_announcement(self, text):
        if not text:
            return
        try:
            if os.path.exists("/usr/bin/spd-say"):
                subprocess.Popen(["spd-say", "-l", "en", "-e", "-C", "hear2read-setup", text],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elif os.path.exists("/usr/bin/espeak-ng"):
                subprocess.Popen(["espeak-ng", "-s", "160", text],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elif os.path.exists("/usr/bin/espeak"):
                subprocess.Popen(["espeak", "-s", "160", text],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    def update_progress(self, percent, text=None):
        fraction = max(0.0, min(1.0, float(percent) / 100.0))
        self.progress_bar.set_fraction(fraction)
        self.progress_bar.set_text(f"{int(fraction * 100)}%")
        if text:
            self.status_label.set_markup(f"<b>{GLib.markup_escape_text(text)}</b>")

    def read_stdin(self):
        for raw_line in sys.stdin:
            line = raw_line.rstrip("\r\n")
            print(line, flush=True)
            GLib.idle_add(self.process_line, line)
        GLib.idle_add(self.on_eof)

    def process_line(self, line):
        if not line: return
        if line.startswith("SOUND"):
            self.play_accessibility_sound(force=True)
            return
        if line.startswith("PERCENT:") or line.startswith("PERCENT "):
            try:
                p = float(line.split(":", 1)[-1].strip().split()[0])
                self.update_progress(p)
            except Exception: pass
            return
        if line.isdigit() and 0 <= int(line) <= 100:
            self.update_progress(int(line))
            return
        if line.startswith("# "):
            msg = line[2:].strip()
            self.status_label.set_markup(f"<b>{GLib.markup_escape_text(msg)}</b>")
            self.append_log(f"[*] {msg}")
            self.play_accessibility_sound(force=True)
            return
        if line.startswith("STATUS:") or line.startswith("STATUS "):
            msg = line.split(":", 1)[-1].strip()
            self.status_label.set_markup(f"<b>{GLib.markup_escape_text(msg)}</b>")
            self.append_log(f"[*] {msg}")
            self.play_accessibility_sound()
            return
        if line.startswith("SUB:"):
            self.sub_label.set_text(line[4:].strip())
            return
        if line.startswith("ERROR:") or line.startswith("ERROR "):
            self.has_error = True
            err_msg = line.split(":", 1)[-1].strip() if ":" in line else line[6:].strip()
            self.last_error_msg = err_msg
            self.status_label.set_markup(f"<span color='#d32f2f'><b>Error: {GLib.markup_escape_text(err_msg)}</b></span>")
            self.append_log(f"[!] ERROR: {err_msg}")
            if not self.scrolled_window.get_visible():
                self.toggle_details(None)
            self.play_accessibility_sound(force=True)
            if hasattr(self, 'speak_announcement'):
                self.speak_announcement(f"Error: {err_msg}")
            return
        if line.startswith("LOG:"):
            msg = line[4:].strip()
            if msg.lower().startswith("error:") and not self.has_error:
                self.has_error = True
                self.last_error_msg = msg
                self.status_label.set_markup(f"<span color='#d32f2f'><b>Error: {GLib.markup_escape_text(msg)}</b></span>")
                self.append_log(f"[!] ERROR: {msg}")
                if not self.scrolled_window.get_visible():
                    self.toggle_details(None)
                self.play_accessibility_sound(force=True)
                if hasattr(self, 'speak_announcement'):
                    self.speak_announcement(f"Error: {msg}")
                return
            self.append_log(msg)
            self.play_accessibility_sound()
            return
        if line in ("COMPLETE", "FINISHED") or line.startswith("COMPLETE:"):
            payload = line.split(":", 1)[1] if ":" in line else ""
            self.on_complete(payload)
            return
        self.append_log(line)
        self.play_accessibility_sound()

    def on_complete(self, payload=""):
        if self.is_completed or self.has_error:
            return
        self.is_completed = True

        lang_name_map = {
            "as": "Assamese", "bn": "Bengali", "gu": "Gujarati", "hi": "Hindi",
            "kn": "Kannada", "ml": "Malayalam", "mr": "Marathi", "ne": "Nepali",
            "or": "Odia", "pa": "Punjabi", "ta": "Tamil", "te": "Telugu",
            "ur": "Urdu", "en": "English"
        }

        # Check installed voice models on disk to confirm ground truth
        installed_langs = []
        installed_voices = []
        for vdir in ["/usr/share/hear2read/Voices", os.path.expanduser("~/.local/share/hear2read/Voices")]:
            if os.path.isdir(vdir):
                for f in sorted(os.listdir(vdir)):
                    if f.endswith(".onnx"):
                        vname = f[:-5]
                        if vname not in installed_voices:
                            installed_voices.append(vname)
                        lcode = f.split("-")[0]
                        if lcode not in installed_langs:
                            installed_langs.append(lcode)

        is_all_removed = (payload == "ALL_REMOVED") or (len(installed_langs) == 0 and not payload.startswith("INSTALLED"))

        if is_all_removed:
            self.update_progress(100, "All Voices Removed")
            self.sub_label.set_text("All Hear2Read voice models have been removed. System speech reverted to eSpeak.")
            self.append_log("[✓] All Hear2Read voice models removed. Reverted to eSpeak.")
            self.play_complete_sound()
            if hasattr(self, 'speak_announcement'):
                self.speak_announcement("All Hear2Read voices removed. System speech has reverted to eSpeak.")

            dialog = Gtk.MessageDialog(
                transient_for=self,
                message_type=Gtk.MessageType.INFO,
                buttons=Gtk.ButtonsType.NONE,
                text="All Hear2Read Voices Removed"
            )
            dialog.set_modal(True)
            dialog.set_destroy_with_parent(True)
            dialog.set_title("Hear2Read Voice Models Removed")
            dialog.set_position(Gtk.WindowPosition.CENTER_ON_PARENT)
            dialog.set_keep_above(True)
            dialog.format_secondary_text(
                "All Hear2Read Indic voice models have been removed from your system.\n\n"
                "System Speech & Orca Screen Reader:\n"
                "• Speech Synthesizer: espeak-ng (eSpeak)\n"
                "• Default Voice: English / system default\n"
                "• Speech Dispatcher routing for Hear2Read has been cleared.\n\n"
                "Your screen reader will now use eSpeak for all speech."
            )
            btn_close = dialog.add_button("_Close", Gtk.ResponseType.CLOSE)
            btn_close.set_can_default(True)
            dialog.set_default_response(Gtk.ResponseType.CLOSE)
            btn_close.grab_focus()
            self.present()
            dialog.show_all()
            dialog.present()
            dialog.run()
            dialog.destroy()
            Gtk.main_quit()
            return

        # Normal completion with installed voices
        self.update_progress(100, "Setup Complete!")
        self.sub_label.set_text("Hear2Read Indic TTS has been installed and configured.")
        self.append_log("[✓] Installation and configuration successfully completed.")
        self.play_complete_sound()
        if hasattr(self, 'speak_announcement'):
            self.speak_announcement("Hear2Read installation completed successfully!")

        active_codes = installed_langs
        default_voice = installed_voices[0] if installed_voices else ""
        if payload.startswith("INSTALLED:"):
            parts = payload[10:].split("|")
            if len(parts) >= 1 and parts[0].strip():
                active_codes = parts[0].strip().split()
            if len(parts) >= 2 and parts[1].strip():
                default_voice = parts[1].strip()

        lang_labels = []
        for code in active_codes:
            name = lang_name_map.get(code, code.upper())
            lang_labels.append(f"{name} ({code})")

        langs_formatted = ", ".join(lang_labels) if lang_labels else "None"

        dialog = Gtk.MessageDialog(
            transient_for=self,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.NONE,
            text="Hear2Read Setup Completed Successfully!"
        )
        dialog.set_modal(True)
        dialog.set_destroy_with_parent(True)
        dialog.set_title("Hear2Read Setup Complete")
        dialog.set_position(Gtk.WindowPosition.CENTER_ON_PARENT)
        dialog.set_keep_above(True)

        dialog.format_secondary_text(
            "The Hear2Read Indic TTS module and selected voice models have been successfully installed.\n\n"
            "To use with Orca Screen Reader:\n"
            "• Open Orca Preferences\n"
            "• Navigate to the Voice tab\n"
            "• Set Speech Synthesizer to 'hear2read'\n\n"
            "Do you want to open Hear2Read Settings now to customize voices and rates?"
        )
        btn_close = dialog.add_button("_Close", Gtk.ResponseType.CLOSE)
        btn_open = dialog.add_button("_Open Hear2Read Settings", Gtk.ResponseType.YES)
        btn_open.set_can_default(True)
        dialog.set_default_response(Gtk.ResponseType.YES)
        btn_open.grab_focus()

        self.present()
        dialog.show_all()
        dialog.present()
        res = dialog.run()
        dialog.destroy()

        if res == Gtk.ResponseType.YES:
            launched = False
            try:
                proc = subprocess.Popen(
                    ["gtk-launch", "hear2read-preferences"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True
                )
                launched = True
            except Exception:
                launched = False

            if not launched:
                script_dir = os.path.dirname(os.path.abspath(__file__))
                mgr_candidates = [
                    "/usr/local/bin/hear2read-manager",
                    "/usr/bin/hear2read-manager",
                    os.path.expanduser("~/.local/bin/hear2read-manager"),
                    "/usr/share/hear2read/hear2read_manager.py",
                    os.path.expanduser("~/.local/share/hear2read/hear2read_manager.py"),
                    os.path.join(script_dir, "hear2read_manager.py"),
                    os.path.join(script_dir, "installer", "hear2read_manager.py")
                ]
                launch_env = os.environ.copy()
                launch_env.pop("NO_AT_BRIDGE", None)
                for mgr in mgr_candidates:
                    if os.path.isfile(mgr):
                        try:
                            cmd = [sys.executable, mgr] if mgr.endswith(".py") else [mgr]
                            subprocess.Popen(
                                cmd,
                                env=launch_env,
                                start_new_session=True,
                                stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
                                close_fds=True
                            )
                            break
                        except Exception:
                            cmd = [sys.executable, mgr] if mgr.endswith(".py") else [mgr]
                            subprocess.Popen(cmd, env=launch_env, start_new_session=True)
                            break
        Gtk.main_quit()

    def on_eof(self):
        if not self.is_completed:
            if self.has_error:
                self.status_label.set_markup("<span color='#d32f2f'><b>Installation Failed</b></span>")
                self.sub_label.set_text(self.last_error_msg or "Installation could not be completed.")
                dialog = Gtk.MessageDialog(
                    transient_for=self,
                    modal=True,
                    message_type=Gtk.MessageType.ERROR,
                    buttons=Gtk.ButtonsType.CLOSE,
                    text="Hear2Read Installation Failed"
                )
                err = self.last_error_msg or "An unexpected error occurred during installation."
                if "authorization" in err.lower() or "privilege" in err.lower() or "root" in err.lower():
                    sec_text = (
                        f"{err}\n\n"
                        "Root privileges are required to configure Speech Dispatcher and install Hear2Read.\n\n"
                        "Please re-run the installer and authorize when prompted, or execute in a terminal:\n"
                        "sudo bash download_and_install_hear2read_module_and_voices.sh"
                    )
                else:
                    sec_text = (
                        f"{err}\n\n"
                        "Please check your internet connection or terminal logs and re-run the installer."
                    )
                dialog.format_secondary_text(sec_text)
                dialog.set_keep_above(True)
                self.present()
                dialog.run()
                dialog.destroy()
                Gtk.main_quit()
            else:
                # If no error occurred and pipeline finished, check if installation succeeded
                if self.progress_bar.get_fraction() >= 0.85:
                    self.on_complete()
                    return
                # Check if voice models exist on disk
                vdirs = ["/usr/share/hear2read/Voices", os.path.expanduser("~/.local/share/hear2read/Voices")]
                has_voices = any(os.path.isdir(d) and any(f.endswith(".onnx") for f in os.listdir(d)) for d in vdirs)
                if has_voices:
                    self.on_complete()
                    return

                self.status_label.set_markup("<span color='#d32f2f'><b>Installation Incomplete</b></span>")
                self.sub_label.set_text("Installation process terminated unexpectedly.")
                dialog = Gtk.MessageDialog(
                    transient_for=self,
                    modal=True,
                    message_type=Gtk.MessageType.WARNING,
                    buttons=Gtk.ButtonsType.CLOSE,
                    text="Hear2Read Installation Incomplete"
                )
                dialog.format_secondary_text(
                    "The installation process terminated before finishing.\n\n"
                    "Please check your internet connection or terminal logs and re-run the installer."
                )
                dialog.set_keep_above(True)
                self.present()
                dialog.run()
                dialog.destroy()
                Gtk.main_quit()

    def on_window_close(self, widget):
        Gtk.main_quit()

def main():
    title = sys.argv[1] if len(sys.argv) > 1 else "Hear2Read Speech-Dispatcher Module"
    subtitle = sys.argv[2] if len(sys.argv) > 2 else None
    win = Hear2ReadProgressWindow(title=title, subtitle=subtitle)
    win.show_all()
    win.scrolled_window.set_visible(False)
    Gtk.main()

if __name__ == "__main__":
    main()
PROGRESS_EOF
    chmod +x "$PROGRESS_PY"
fi

# ==============================================================================
# AUDIO TICKER HELPERS (INDEPENDENT TIMER FOR SOUND FEEDBACK)
# ==============================================================================
ensure_local_beep_wav() {
    if [ ! -f /tmp/hear2read_beep.wav ]; then
        python3 -c "
import wave, math, struct
try:
    with wave.open('/tmp/hear2read_beep.wav', 'w') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(22050)
        n = int(22050 * 0.07)
        frames = [struct.pack('<h', int((1.0 - i/n) * 14000 * math.sin(2 * math.pi * 800 * i / 22050))) for i in range(n)]
        f.writeframes(b''.join(frames))
except Exception: pass
" 2>/dev/null || true
    fi
}

start_audio_ticker() {
    ensure_local_beep_wav
    TICKER_STOP_FILE="/tmp/h2r_ticker_stop_$$"
    rm -f "$TICKER_STOP_FILE"
    (
        while [ ! -f "$TICKER_STOP_FILE" ]; do
            sleep 2
            if [ -f "$TICKER_STOP_FILE" ]; then break; fi
            if command -v paplay >/dev/null 2>&1 && [ -f /tmp/hear2read_beep.wav ]; then
                paplay /tmp/hear2read_beep.wav >/dev/null 2>&1 || true
            elif command -v aplay >/dev/null 2>&1 && [ -f /tmp/hear2read_beep.wav ]; then
                aplay -q /tmp/hear2read_beep.wav >/dev/null 2>&1 || true
            elif command -v canberra-gtk-play >/dev/null 2>&1; then
                canberra-gtk-play -i audio-volume-change -d "Hear2Read Setup" >/dev/null 2>&1 || true
            else
                printf '\a' >/dev/tty 2>/dev/null || true
            fi
        done
    ) &
    TICKER_PID=$!
}

stop_audio_ticker() {
    if [ -n "$TICKER_PID" ]; then
        touch "/tmp/h2r_ticker_stop_$$" 2>/dev/null || true
        kill -9 "$TICKER_PID" 2>/dev/null || true
        wait "$TICKER_PID" 2>/dev/null || true
        rm -f "/tmp/h2r_ticker_stop_$$" 2>/dev/null || true
        unset TICKER_PID
    fi
}

# ==============================================================================
# STEP 2: STEPPED PROGRESS INSTALLATION PIPELINE
# ==============================================================================
run_installation_pipeline() {
    echo "5"
    echo "# Step 1/6: Verifying core package and synthesizer engine..."
    echo "LOG: Checking user permissions and system environment..."

    HAS_ROOT=0
    SUDO_KEEPALIVE_PID=""
    ROOT_SCRIPT="/tmp/h2r_install_root_$$.sh"
    printf '#!/bin/sh\nset +e\n' > "$ROOT_SCRIPT"

    cleanup_root() {
        [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        rm -f "$ROOT_SCRIPT" 2>/dev/null || true
    }
    trap cleanup_root EXIT INT TERM

    # --- Step 1: Determine administrator privileges ---
    if [ "$EUID" -eq 0 ]; then
        HAS_ROOT=1
    elif sudo -n true 2>/dev/null; then
        HAS_ROOT=1
        ( while true; do sudo -n -v 2>/dev/null; sleep 50; done ) &
        SUDO_KEEPALIVE_PID=$!
    elif ([ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]) && command -v pkexec >/dev/null 2>&1; then
        HAS_ROOT=1
        # pkexec path: all root operations will be batched into $ROOT_SCRIPT and executed ONCE at deployment
    elif command -v sudo >/dev/null 2>&1; then
        echo "LOG: Requesting administrator password in terminal..."
        if sudo -v; then
            HAS_ROOT=1
            ( while true; do sudo -n -v 2>/dev/null; sleep 50; done ) &
            SUDO_KEEPALIVE_PID=$!
        else
            HAS_ROOT=0
            echo "ERROR: Administrator authorization was not granted."
            echo "LOG: Root privileges are strictly required to configure Speech Dispatcher and install Hear2Read."
            sleep 1.0
            exit 1
        fi
    else
        HAS_ROOT=0
        echo "ERROR: No authorization tool (pkexec or sudo) is available."
        echo "LOG: Root privileges are strictly required to install Hear2Read."
        exit 1
    fi

    # Fail fast assertion: Installation cannot proceed without root
    if [ "$HAS_ROOT" -ne 1 ]; then
        echo "ERROR: Administrator authorization was not granted."
        echo "LOG: Root privileges are strictly required to configure Speech Dispatcher and install Hear2Read."
        sleep 1.0
        exit 1
    fi

    # run_as_root: executes immediately if root/sudo is active, otherwise queues to $ROOT_SCRIPT
    run_as_root() {
        [ "$HAS_ROOT" -eq 0 ] && return 1
        if [ "$EUID" -eq 0 ]; then
            "$@" 2>/dev/null || true
        elif [ -n "$SUDO_KEEPALIVE_PID" ] || sudo -n true 2>/dev/null; then
            sudo -n "$@" 2>/dev/null || true
        else
            local cmd=""
            for arg in "$@"; do
                cmd="$cmd $(printf '%q' "$arg")"
            done
            echo "$cmd" >> "$ROOT_SCRIPT"
        fi
    }

    flush_root() {
        if [ -s "$ROOT_SCRIPT" ] && grep -qv '^#\|^set \|^$' "$ROOT_SCRIPT" 2>/dev/null; then
            echo "LOG: Applying system-wide configurations (requesting authorization)..."
            local rc=0
            if ([ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]) && command -v pkexec >/dev/null 2>&1; then
                pkexec sh "$ROOT_SCRIPT" || rc=$?
            else
                sudo sh "$ROOT_SCRIPT" || rc=$?
            fi
            if [ $rc -ne 0 ]; then
                echo "ERROR: Administrator authorization was not granted."
                echo "LOG: Root privileges are strictly required to configure Speech Dispatcher and install Hear2Read."
                exit 1
            fi
            printf '#!/bin/sh\nset +e\n' > "$ROOT_SCRIPT"
        fi
    }

    if [ "$HAS_ROOT" -eq 1 ]; then
        echo "LOG: Creating system directory structures..."
        run_as_root mkdir -p "$VOICES_DIR_SYS" "$MODULE_SYS" /etc/speech-dispatcher/modules /usr/share/hear2read /usr/local/bin /usr/local/lib /usr/share/applications
        run_as_root chmod 755 "$VOICES_DIR_SYS"
    fi


    INSTALLED_VER=$(get_installed_version)
    SKIP_CORE_INSTALL=0
    if is_module_installed; then
        if [ "$INSTALLED_VER" = "$MODULE_VERSION" ] && [ -f "$MODULE_SYS/sd_hear2read" ] && [ -f "/usr/local/lib/libhear2readng.so" ]; then
            SKIP_CORE_INSTALL=1
        fi
    fi

    if [ "$SKIP_CORE_INSTALL" -eq 1 ]; then
        echo "15"
        echo "LOG: Core module v${MODULE_VERSION} is already up-to-date and functional on this system."
        echo "LOG: Skipping core re-installation and managing voices..."
        if [ ! -f "$APP_DIR/version.txt" ]; then
            echo "$MODULE_VERSION" > "$APP_DIR/version.txt" 2>/dev/null || true
        fi
    else
        if [ -n "$INSTALLED_VER" ]; then
            echo "LOG: Upgrading Hear2Read module from v${INSTALLED_VER} to v${MODULE_VERSION} (voices preserved)..."
        else
            echo "LOG: Setting up Hear2Read core module v${MODULE_VERSION}..."
        fi

        TMP_BUNDLE="/tmp/hear2read-linux.tar.gz"
        # Always prioritize local updated tar.gz from script directory, current dir, or Downloads
        LOCAL_BUNDLE=""
        for lcand in "$SCRIPT_DIR/hear2read-linux.tar.gz" \
                     "$SCRIPT_DIR/../hear2read-linux.tar.gz" \
                     "$PWD/hear2read-linux.tar.gz" \
                     "$PWD/../hear2read-linux.tar.gz" \
                     "$HOME/Downloads/hear2read-linux.tar.gz"; do
            if [ -f "$lcand" ] && [ -s "$lcand" ]; then
                LOCAL_BUNDLE="$lcand"
                break
            fi
        done

        if [ -n "$LOCAL_BUNDLE" ]; then
            echo "LOG: Using local package copy from $LOCAL_BUNDLE..."
            cp -f "$LOCAL_BUNDLE" "$TMP_BUNDLE"
        elif [ ! -f "$TMP_BUNDLE" ] || [ ! -s "$TMP_BUNDLE" ] || [ "$INSTALLED_VER" != "$MODULE_VERSION" ]; then
            rm -f "$TMP_BUNDLE"
            echo "LOG: Downloading hear2read-linux.tar.gz v${MODULE_VERSION} from GitHub Releases..."
            download_success=0
            for url in "$GITHUB_BUNDLE_URL" "$GITHUB_BUNDLE_FALLBACK"; do
                echo "LOG: Fetching $url..."
                if command -v curl >/dev/null 2>&1; then
                    curl -4 -fSL --connect-timeout 10 --speed-limit 1024 --speed-time 20 --max-time 120 --retry 2 -C - -o "$TMP_BUNDLE" "$url" 2>&1 | grep -v "%" | while read -r line; do
                        [ -n "$line" ] && echo "LOG: $line"
                    done || true
                elif command -v wget >/dev/null 2>&1; then
                    wget -4 -q --connect-timeout=10 --timeout=45 --tries=2 -c -O "$TMP_BUNDLE" "$url" 2>&1 | while read -r line; do
                        [ -n "$line" ] && echo "LOG: $line"
                    done || true
                fi
                if [ -f "$TMP_BUNDLE" ] && [ -s "$TMP_BUNDLE" ]; then
                    download_success=1
                    break
                fi
            done

            if [ "$download_success" -eq 0 ]; then
                echo "LOG: Warning: Could not download hear2read-linux.tar.gz from GitHub Releases."
            fi
        fi

        if [ -f "$TMP_BUNDLE" ] && [ -s "$TMP_BUNDLE" ]; then
            echo "12"
            echo "# Step 1/6: Extracting core bundle..."
            mkdir -p /tmp/hear2read_extract
            tar -xzf "$TMP_BUNDLE" -C /tmp/hear2read_extract 2>/dev/null || true
            if [ -d "/tmp/hear2read_extract/hear2read_dist" ]; then
                SCRIPT_DIR="/tmp/hear2read_extract/hear2read_dist"
            elif [ -d "/tmp/hear2read_extract" ]; then
                SCRIPT_DIR="/tmp/hear2read_extract"
            fi
            echo "LOG: Core package extracted successfully to $SCRIPT_DIR."
        else
            echo "LOG: WARNING: hear2read-linux.tar.gz was not found locally or on GitHub."
            echo "LOG: Place hear2read-linux.tar.gz in ~/Downloads or the script directory to install core engine."
        fi

        cd "$SCRIPT_DIR"

        # Compile sd_hear2read if binary is missing and source is available
        if [ ! -f "sd_hear2read" ] && [ -f "sd_hear2read.c" ]; then
            echo "LOG: Compiling native sd_hear2read module..."
            gcc -O2 -fPIC -o sd_hear2read sd_hear2read.c script_router.c espeak_bridge.c \
                -L. -lhear2readng -lespeak-ng -lpulse-simple -lpulse -lrt -lpthread -lm -I./include \
                -Wl,-rpath,'$ORIGIN:$ORIGIN/lib:$ORIGIN/../lib:/usr/local/lib:$HOME/.local/lib:/usr/lib' 2>&1 | while read -r cline; do
                    echo "LOG: $cline"
                done || true
        fi

        # Deploy binary to system locations with absolute path
        BIN_SRC=""
        if [ -f "$SCRIPT_DIR/sd_hear2read" ]; then
            BIN_SRC="$SCRIPT_DIR/sd_hear2read"
        elif [ -f "$SCRIPT_DIR/../sd_hear2read" ]; then
            BIN_SRC="$SCRIPT_DIR/../sd_hear2read"
        elif [ -f "sd_hear2read" ]; then
            BIN_SRC="$(pwd)/sd_hear2read"
        elif [ -f "$MODULE_SYS/sd_hear2read" ]; then
            BIN_SRC="$MODULE_SYS/sd_hear2read"
        fi

        if [ -z "$BIN_SRC" ] || [ ! -f "$BIN_SRC" ]; then
            echo "ERROR: Failed to locate or compile core sd_hear2read binary."
            echo "LOG: Error: Core engine binary could not be found or built."
            exit 1
        fi

        echo "LOG: Staging sd_hear2read binary for system installation ($MODULE_SYS)..."
        if [ "$HAS_ROOT" -eq 1 ]; then
            run_as_root mkdir -p "$MODULE_SYS" /usr/local/bin
            run_as_root cp -f "$BIN_SRC" "$MODULE_SYS/sd_hear2read"
            run_as_root chmod 755 "$MODULE_SYS/sd_hear2read"
            run_as_root cp -f "$BIN_SRC" /usr/local/bin/sd_hear2read
            run_as_root chmod 755 /usr/local/bin/sd_hear2read
        fi
        # Clean up any legacy user-local binary copies
        rm -f "$MODULE_USER/sd_hear2read" "$HOME/.local/bin/sd_hear2read" 2>/dev/null || true

        # Deploy shared libraries strictly to system
        if [ ! -f "$SCRIPT_DIR/libhear2readng.so" ] && [ ! -f "/usr/local/lib/libhear2readng.so" ]; then
            echo "ERROR: Core shared library libhear2readng.so is missing."
            echo "LOG: Error: libhear2readng.so could not be found."
            exit 1
        fi
        if [ -f "$SCRIPT_DIR/libhear2readng.so" ]; then
            echo "LOG: Staging shared libraries for /usr/local/lib/..."
            if [ "$HAS_ROOT" -eq 1 ]; then
                run_as_root mkdir -p /usr/local/lib
                run_as_root cp -f "$SCRIPT_DIR/libhear2readng.so" /usr/local/lib/
                run_as_root chmod 755 /usr/local/lib/libhear2readng.so 2>/dev/null || true
                if [ -d "$SCRIPT_DIR/lib" ]; then
                    run_as_root cp -d "$SCRIPT_DIR/lib/"*.so* /usr/local/lib/ 2>/dev/null || true
                fi
                run_as_root ldconfig 2>/dev/null || true
            fi
            # Clean up any legacy user-local library copies
            rm -f "$HOME/.local/lib/libhear2readng.so" "$HOME/.local/lib/"libonnxruntime* 2>/dev/null || true
        fi

        # Write version stamp for system
        echo "$MODULE_VERSION" > /tmp/hear2read_version.txt
        if [ "$HAS_ROOT" -eq 1 ]; then
            run_as_root mkdir -p /usr/share/hear2read
            run_as_root cp -f /tmp/hear2read_version.txt /usr/share/hear2read/version.txt
            run_as_root chmod 644 /usr/share/hear2read/version.txt
        fi
    fi

    echo "18"
    echo "LOG: Core engine and module staged for installation."
    sleep 0.5

    # ==============================================================================
    # STEP 2: VOICE MANAGEMENT (DELETION & DOWNLOAD)
    # ==============================================================================
    echo "20"
    echo "# Step 2/6: Managing voice models..."
    start_audio_ticker

    # 1. Process unchecked voices (deletion)
    if [ ${#DELETED_CODES[@]} -gt 0 ]; then
        echo "LOG: Removing unchecked voice models: ${DELETED_CODES[*]}..."
        for dcode in "${DELETED_CODES[@]}"; do
            dname="${LANG_NAMES[$dcode]:-$dcode}"
            echo "LOG: Removing $dname ($dcode) voice models from disk..."
            if [ -d "$VOICES_DIR_USER" ]; then
                rm -f "$VOICES_DIR_USER"/"$dcode"-*.onnx "$VOICES_DIR_USER"/"$dcode"-*.onnx.json 2>/dev/null || true
            fi
            if [ -d "$VOICES_DIR_SYS" ]; then
                if [ "$HAS_ROOT" -eq 1 ]; then
                    run_as_root rm -f "$VOICES_DIR_SYS"/"$dcode"-*.onnx "$VOICES_DIR_SYS"/"$dcode"-*.onnx.json 2>/dev/null || true
                elif [ -w "$VOICES_DIR_SYS" ]; then
                    rm -f "$VOICES_DIR_SYS"/"$dcode"-*.onnx "$VOICES_DIR_SYS"/"$dcode"-*.onnx.json 2>/dev/null || true
                fi
            fi
            echo "LOG: Voice model for $dname ($dcode) deleted."
        done
    fi

    VOICES_STAGING="/tmp/hear2read_voices_staging"
    rm -rf "$VOICES_STAGING"
    mkdir -p "$VOICES_STAGING"

    # Migrate any legacy user voices from VOICES_DIR_USER into staging
    if [ -d "$VOICES_DIR_USER" ]; then
        for uf in "$VOICES_DIR_USER"/*; do
            if [ -f "$uf" ]; then
                cp -n "$uf" "$VOICES_STAGING/" 2>/dev/null || true
            fi
        done
        rm -rf "$VOICES_DIR_USER" 2>/dev/null || true
    fi

    # Copy any pre-bundled voices from distribution package if present
    if [ -d "$SCRIPT_DIR/Voices" ]; then
        for vf in "$SCRIPT_DIR/Voices"/*; do
            if [ -e "$vf" ]; then
                echo "LOG: Copying bundled voice $(basename "$vf")..."
                cp -rn "$vf" "$VOICES_STAGING/" 2>/dev/null || true
            fi
        done
    fi

    # Determine voices that need downloading
    VOICES_TO_DOWNLOAD=()
    for code in $SELECTED_CODES; do
        if ! is_voice_installed "$code" && [ ! -f "$VOICES_STAGING/$code"-*.onnx ]; then
            VOICES_TO_DOWNLOAD+=("$code")
        else
            echo "LOG: Language ${LANG_NAMES[$code]} ($code) is already present."
        fi
    done

    TOTAL_NEEDED=${#VOICES_TO_DOWNLOAD[@]}
    CURRENT_INDEX=0
    FAILED_VOICES=()
    SUCCESSFUL_VOICES=()

    if [ "$TOTAL_NEEDED" -eq 0 ]; then
        echo "LOG: Voice models are up-to-date."
        sleep 0.5
    else
        echo "LOG: Downloading $TOTAL_NEEDED voice model package(s)..."
        for code in "${VOICES_TO_DOWNLOAD[@]}"; do
            name="${LANG_NAMES[$code]}"
            pkg_file="${LANG_FILES[$code]}"
            github_url="$GITHUB_VOICE_BASE/$pkg_file"

            step_pct=$(( 20 + (45 * CURRENT_INDEX) / TOTAL_NEEDED ))
            echo "$step_pct"
            echo "# Step 2/6: Downloading $name voice package ($((CURRENT_INDEX + 1))/$TOTAL_NEEDED)..."
            echo "SUB: Downloading $name ($code)..."
            echo "SOUND"

            tmp_archive="/tmp/${code}_archive.tar.xz"
            rm -f "$tmp_archive"
            downloaded=0

            echo "LOG: Downloading $name from GitHub Releases CDN..."
            if command -v curl >/dev/null 2>&1; then
                curl -4 -fSL --connect-timeout 10 --speed-limit 1024 --speed-time 20 --max-time 180 --retry 2 -C - -o "$tmp_archive" "$github_url" 2>&1 | grep -v "%" | while read -r dline; do
                    [ -n "$dline" ] && echo "LOG: $dline"
                done || true
            elif command -v wget >/dev/null 2>&1; then
                wget -4 -q --connect-timeout=10 --timeout=60 --tries=2 -c -O "$tmp_archive" "$github_url" 2>&1 | while read -r dline; do
                    [ -n "$dline" ] && echo "LOG: $dline"
                done || true
            fi

            if [ -f "$tmp_archive" ] && [ -s "$tmp_archive" ]; then
                downloaded=1
            fi

            if [ "$downloaded" -eq 1 ]; then
                archive_size=$(du -h "$tmp_archive" | cut -f1)
                echo "LOG: Download completed for $name ($archive_size)."
                echo "LOG: Extracting $name voice package..."
                tar -xf "$tmp_archive" -C "$VOICES_STAGING" 2>&1 | while read -r eline; do
                    echo "LOG: $eline"
                done || true
                rm -f "$tmp_archive"

                installed_onnx=$(ls -1 "$VOICES_STAGING"/"$code"-*.onnx 2>/dev/null | head -n 1 || true)
                if [ -n "$installed_onnx" ]; then
                    onnx_size=$(du -h "$installed_onnx" | cut -f1)
                    echo "LOG: Verified voice model: $(basename "$installed_onnx") ($onnx_size)"
                    SUCCESSFUL_VOICES+=("$name")
                else
                    FAILED_VOICES+=("$name")
                    echo "ERROR: Failed to extract valid voice model for $name."
                fi
                echo "SOUND"
                sleep 0.5
            else
                FAILED_VOICES+=("$name")
                echo "LOG: Error: Failed to download $name package from GitHub Releases ($github_url)."
                echo "ERROR: Failed to download $name voice package."
            fi

            CURRENT_INDEX=$((CURRENT_INDEX + 1))
        done
    fi

    stop_audio_ticker

    # Validate voice downloads
    if [ "$TOTAL_NEEDED" -gt 0 ] && [ ${#SUCCESSFUL_VOICES[@]} -eq 0 ]; then
        EXISTING_VOICE_COUNT=$(ls -1 "$VOICES_DIR_SYS"/*.onnx 2>/dev/null | wc -l)
        if [ "$EXISTING_VOICE_COUNT" -eq 0 ]; then
            echo "ERROR: Failed to download voice model(s). Please check your internet connection."
            echo "LOG: Error: Voice download failed and no existing voice models are installed."
            exit 1
        else
            echo "ERROR: Failed to download requested voice model(s) (${FAILED_VOICES[*]})."
            echo "LOG: Warning: Retaining previously installed voice models."
        fi
    elif [ ${#FAILED_VOICES[@]} -gt 0 ]; then
        echo "LOG: Warning: Some voice models failed to download: ${FAILED_VOICES[*]}."
    fi

    # Queue staged voices for system-wide installation
    if [ "$HAS_ROOT" -eq 1 ] && [ -d "$VOICES_STAGING" ]; then
        if [ -n "$(ls -A "$VOICES_STAGING" 2>/dev/null)" ]; then
            run_as_root mkdir -p "$VOICES_DIR_SYS"
            run_as_root cp -rn "$VOICES_STAGING"/* "$VOICES_DIR_SYS/"
            run_as_root chmod -R 755 "$VOICES_DIR_SYS"
        fi
    fi

    echo "65"
    echo "LOG: Voice models management stage completed."
    sleep 0.5

    # ==============================================================================
    # STEP 3: CONFIGURE SPEECH DISPATCHER MODULE (DYNAMIC)
    # ==============================================================================
    echo "68"
    echo "# Step 3/6: Configuring Speech Dispatcher module..."
    echo "LOG: Generating dynamic hear2read.conf configuration file..."

    TMP_CONF="/tmp/hear2read.conf"
    cat << 'MODULE_CONF' > "$TMP_CONF"
# Hear2Read Speech-Dispatcher Configuration
GenericExecuteSynth = "sd_hear2read"
GenericCmdDependency = "sd_hear2read"

MODULE_CONF

    DISCOVERED_LANGS=()
    DEFAULT_VOICE=""

    # Discover all present .onnx models on disk and in staging
    for vdir in "$VOICES_DIR_SYS" "$VOICES_STAGING"; do
        if [ -d "$vdir" ]; then
            for onnx_path in "$vdir"/*.onnx; do
                if [ -f "$onnx_path" ]; then
                    base_onnx=$(basename "$onnx_path" .onnx)
                    if [[ "$base_onnx" =~ ^([a-z]{2,3})-(.+) ]]; then
                        lang_c="${BASH_REMATCH[1]}"
                        # Skip if this voice was explicitly deleted
                        is_deleted=0
                        for dc in "${DELETED_CODES[@]}"; do
                            if [ "$dc" = "$lang_c" ]; then is_deleted=1; break; fi
                        done
                        [ $is_deleted -eq 1 ] && continue

                        found_dl=0
                        for dl in "${DISCOVERED_LANGS[@]}"; do
                            if [ "$dl" = "$lang_c" ]; then found_dl=1; break; fi
                        done
                        if [ $found_dl -eq 0 ]; then
                            DISCOVERED_LANGS+=("$lang_c")
                        fi
                        if [ -z "$DEFAULT_VOICE" ]; then
                            DEFAULT_VOICE="$base_onnx"
                        fi
                        echo "AddVoice \"$lang_c\" \"MALE1\" \"$base_onnx\"" >> "$TMP_CONF"
                    fi
                fi
            done
        fi
    done

    if [ -n "$DEFAULT_VOICE" ]; then
        echo "DefaultVoice \"$DEFAULT_VOICE\"" >> "$TMP_CONF"
    fi
    echo 'AudioOutputMethod "server"' >> "$TMP_CONF"
    echo 'DefaultRate 0' >> "$TMP_CONF"
    echo 'DefaultPitch 0' >> "$TMP_CONF"
    echo 'DefaultVolume 90' >> "$TMP_CONF"

    # Copy strictly to system configuration
    if [ "$HAS_ROOT" -eq 1 ]; then
        run_as_root mkdir -p /etc/speech-dispatcher/modules
        run_as_root cp -f "$TMP_CONF" "$CONF_SYS"
        run_as_root chmod 644 "$CONF_SYS"
    fi
    # Clean up legacy user module configuration so it does not shadow system configuration
    rm -f "$HOME/.config/speech-dispatcher/modules/hear2read.conf" 2>/dev/null || true
    echo "LOG: Configured hear2read.conf with ${#DISCOVERED_LANGS[@]} configured Indic voice(s)."
    if [ "${#DISCOVERED_LANGS[@]}" -eq 0 ]; then
        # ==============================================================================
        # ALL VOICES REMOVED: Clean revert to default eSpeak
        # ==============================================================================
        echo "LOG: No Indic voice models remain. Reverting system speech to eSpeak..."

        # Remove hear2read from system speechd.conf
        if [ -f "$SPEECHD_CONF" ]; then
            local tmp_revert="/tmp/speechd_revert_$$.conf"
            grep -v -E '(sd_hear2read|LanguageDefaultModule .* "hear2read"|# Hear2Read Synthesiser Module)' "$SPEECHD_CONF" > "$tmp_revert" || true
            run_as_root cp -f "$tmp_revert" "$SPEECHD_CONF"
            run_as_root chmod 644 "$SPEECHD_CONF"
            rm -f "$tmp_revert" 2>/dev/null || true
        fi

        # Also purge hear2read from user-level speechd.conf if present
        local user_spd="$HOME/.config/speech-dispatcher/speechd.conf"
        if [ -f "$user_spd" ]; then
            local tmp_user_revert="/tmp/user_spd_revert_$$.conf"
            grep -v -E '(sd_hear2read|LanguageDefaultModule .* "hear2read"|# Hear2Read Synthesiser Module)' "$user_spd" > "$tmp_user_revert" || true
            cp -f "$tmp_user_revert" "$user_spd" 2>/dev/null || true
            rm -f "$tmp_user_revert" 2>/dev/null || true
        fi

        # Remove hear2read module configuration file
        run_as_root rm -f "$CONF_SYS" 2>/dev/null || true
        rm -f "$HOME/.config/speech-dispatcher/modules/hear2read.conf" 2>/dev/null || true

        # Flush all queued root operations now
        flush_root

        # Revert Orca preferences back to default eSpeak across all profiles
        python3 -c '
import json, os
p = os.path.expanduser("~/.local/share/orca/user-settings.conf")
if os.path.isfile(p):
    try:
        with open(p, "r") as f:
            data = json.load(f)

        def clean_section(sec):
            if not isinstance(sec, dict):
                return
            sec["enableSpeech"] = True
            sec["speechServerFactory"] = "orca.speechdispatcherfactory"
            sec["speechServerInfo"] = ["Default Synthesizer", "default"]
            voices = sec.get("voices", {})
            for key in list(voices.keys()):
                fam = voices[key].get("family", {})
                name = str(fam.get("name", "")).lower()
                lang = str(fam.get("lang", "")).lower()
                if any(term in name for term in ["tdil", "hear2read", "zha"]) or (lang and lang != "en"):
                    del voices[key]
            if "default" in voices:
                voices["default"].setdefault("family", {})["lang"] = "en"
                voices["default"]["family"].pop("name", None)

        clean_section(data.setdefault("general", {}))
        for prof in data.get("profiles", {}).values():
            clean_section(prof)

        with open(p, "w") as f:
            json.dump(data, f, indent=2)
        print("LOG: Orca preferences reverted to Default Synthesizer across all profiles.")
    except Exception as ex:
        print("LOG: Warning: Could not update Orca preferences:", ex)
' 2>/dev/null || true

        # Restart Speech Dispatcher cleanly
        if command -v systemctl >/dev/null 2>&1; then
            timeout 3s systemctl --user stop speech-dispatcher.service 2>/dev/null || true
            timeout 3s systemctl --user stop speech-dispatcher.socket 2>/dev/null || true
        fi
        killall -9 speech-dispatcher sd_hear2read 2>/dev/null || true
        rm -rf "/run/user/$(id -u)/speech-dispatcher"/* 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
            timeout 3s systemctl --user daemon-reload 2>/dev/null || true
            timeout 5s systemctl --user --no-block restart speech-dispatcher.socket 2>/dev/null || true
            timeout 5s systemctl --user --no-block restart speech-dispatcher.service 2>/dev/null || true
        fi
        sleep 0.5

        # Reload Orca cleanly if running so it picks up the eSpeak revert
        if pgrep -f "[o]rca" >/dev/null 2>&1; then
            echo "LOG: Reloading Orca with default eSpeak settings..."
            if command -v systemd-run >/dev/null 2>&1; then
                systemd-run --user orca --replace >/dev/null 2>&1 || setsid orca --replace </dev/null >/dev/null 2>&1 &
            elif command -v setsid >/dev/null 2>&1; then
                setsid orca --replace </dev/null >/dev/null 2>&1 &
            else
                nohup orca --replace </dev/null >/dev/null 2>&1 &
            fi
        fi

        echo "100"
        echo "# All Hear2Read voice models removed."
        echo "LOG: All Indic voice models have been removed. System speech has reverted to eSpeak."
        echo "COMPLETE:ALL_REMOVED"
        sleep 1.0
        return 0
    fi

    # Dynamic update of speechd.conf
    update_speechd_conf_file() {
        local conf_file="$1"
        local use_root="$2"
        if [ ! -f "$conf_file" ]; then return; fi

        echo "LOG: Updating Speech Dispatcher routing in $conf_file..."
        local tmp_spd="/tmp/speechd_tmp_${use_root}_$$.conf"

        # 1. Purge all existing hear2read lines to eliminate any orphaned routing
        grep -v -E '(sd_hear2read|LanguageDefaultModule .* "hear2read"|# Hear2Read Synthesiser Module)' "$conf_file" > "$tmp_spd" || true

        # 2. Add module declaration with absolute path so it works with both system and user configurations
        echo "" >> "$tmp_spd"
        echo '# Hear2Read Synthesiser Module' >> "$tmp_spd"
        echo 'AddModule "hear2read" "sd_hear2read" "/etc/speech-dispatcher/modules/hear2read.conf"' >> "$tmp_spd"

        # 4. Write back
        if [ "$use_root" -eq 1 ] && [ "$HAS_ROOT" -eq 1 ]; then
            run_as_root cp -f "$tmp_spd" "$conf_file"
            run_as_root chmod 644 "$conf_file"
        else
            cp -f "$tmp_spd" "$conf_file" 2>/dev/null || true
            rm -f "$tmp_spd" 2>/dev/null || true
        fi
    }

    if [ -f "$SPEECHD_CONF" ]; then
        update_speechd_conf_file "$SPEECHD_CONF" 1
    fi

    # Back up legacy user speechd.conf override so Speech Dispatcher reads system /etc/speech-dispatcher/
    USER_SPEECHD_CONF="$HOME/.config/speech-dispatcher/speechd.conf"
    if [ -f "$USER_SPEECHD_CONF" ]; then
        echo "LOG: Archiving legacy user speechd.conf override to speechd.conf.bak..."
        mv -f "$USER_SPEECHD_CONF" "$USER_SPEECHD_CONF.bak" 2>/dev/null || true
    fi
    mkdir -p "$HOME/.config/speech-dispatcher/modules" 2>/dev/null || true
    ln -sf /etc/speech-dispatcher/modules/hear2read.conf "$HOME/.config/speech-dispatcher/modules/hear2read.conf" 2>/dev/null || true

    echo "78"
    echo "LOG: Speech Dispatcher dynamic routing updated successfully."

    # Sync Orca preferences to point at Hear2Read with the first installed language
    if [ -n "$DEFAULT_VOICE" ] && [ "${#DISCOVERED_LANGS[@]}" -gt 0 ]; then
        first_lang="${DISCOVERED_LANGS[0]}"
        echo "LOG: Synchronizing Orca preferences to Hear2Read ($first_lang / $DEFAULT_VOICE)..."
        python3 -c "
import json, os
p = os.path.expanduser('~/.local/share/orca/user-settings.conf')
os.makedirs(os.path.dirname(p), exist_ok=True)
data = {}
if os.path.isfile(p):
    try:
        with open(p, 'r') as f:
            data = json.load(f)
    except Exception:
        data = {}
gen = data.setdefault('general', {})
gen['enableSpeech'] = True
gen['speechServerFactory'] = 'orca.speechdispatcherfactory'
gen['speechServerInfo'] = ['Hear2Read', 'hear2read']
voices = gen.setdefault('voices', {})
dv = voices.setdefault('default', {})
fam = dv.setdefault('family', {})
fam['lang'] = '$first_lang'
fam['name'] = '$DEFAULT_VOICE'
dv['established'] = True
data['general'] = gen
for prof in data.get('profiles', {}).values():
    if isinstance(prof, dict):
        prof['speechServerInfo'] = ['Hear2Read', 'hear2read']
        pv = prof.setdefault('voices', {})
        pdv = pv.setdefault('default', {})
        pfam = pdv.setdefault('family', {})
        pfam['lang'] = '$first_lang'
        pfam['name'] = '$DEFAULT_VOICE'
        pdv['established'] = True
try:
    with open(p, 'w') as f:
        json.dump(data, f, indent=2)
    print('LOG: Orca preferences synced to Hear2Read across all profiles.')
except Exception as ex:
    print('LOG: Warning: Could not sync Orca preferences:', ex)
" 2>/dev/null || true
    fi
    sleep 0.5

    # ==============================================================================
    # STEP 4: INSTALL UNIVERSAL DESKTOP LAUNCHER & PREFERENCES MANAGER
    # ==============================================================================
    echo "80"
    echo "# Step 4/6: Installing universal desktop launcher..."
    echo "LOG: Installing GUI Preferences Manager to /usr/share/hear2read/..."

    # Locate hear2read_manager.py across all possible candidate locations
    MGR_SRC=""
    for cand in "$SCRIPT_DIR/hear2read_manager.py" \
                "$SCRIPT_DIR/installer/hear2read_manager.py" \
                "/tmp/hear2read_extract/hear2read_dist/hear2read_manager.py" \
                "/tmp/hear2read_extract/installer/hear2read_manager.py" \
                "/tmp/hear2read_extract/hear2read_manager.py" \
                "$PWD/installer/hear2read_manager.py" \
                "$PWD/hear2read_manager.py" \
                "$HOME/Downloads/hear2read_manager.py" \
                "$HOME/Downloads/hear2read_dist/hear2read_manager.py"; do
        if [ -f "$cand" ]; then
            MGR_SRC="$cand"
            break
        fi
    done

    HELPERS_STAGE="/tmp/h2r_helpers"
    rm -rf "$HELPERS_STAGE"
    mkdir -p "$HELPERS_STAGE"
    mkdir -p "$HOME/.local/share/hear2read" "$HOME/.local/bin"

    if [ -n "$MGR_SRC" ]; then
        cp -f "$MGR_SRC" "$HELPERS_STAGE/hear2read_manager.py"
        chmod +x "$HELPERS_STAGE/hear2read_manager.py"
        # Always install user copy
        cp -f "$HELPERS_STAGE/hear2read_manager.py" "$HOME/.local/share/hear2read/hear2read_manager.py"
        chmod 755 "$HOME/.local/share/hear2read/hear2read_manager.py"
        if [ "$HAS_ROOT" -eq 1 ]; then
            run_as_root mkdir -p /usr/share/hear2read /usr/local/bin
            run_as_root cp -f "$HELPERS_STAGE/hear2read_manager.py" /usr/share/hear2read/hear2read_manager.py
            run_as_root chmod 755 /usr/share/hear2read/hear2read_manager.py
            run_as_root rm -f /usr/local/bin/hear2read-manager
            run_as_root ln -sf /usr/share/hear2read/hear2read_manager.py /usr/local/bin/hear2read-manager
        fi
    fi

    # Helper script staging and queuing
    for helper in "voice_selector.py" "progress_ui.py" "uninstall_hear2read.sh"; do
        H_SRC=""
        for cand in "$SCRIPT_DIR/$helper" \
                    "$SCRIPT_DIR/installer/$helper" \
                    "/tmp/hear2read_extract/hear2read_dist/$helper" \
                    "/tmp/hear2read_extract/installer/$helper" \
                    "/tmp/hear2read_extract/$helper" \
                    "$PWD/installer/$helper" \
                    "$PWD/$helper"; do
            if [ -f "$cand" ]; then
                H_SRC="$cand"
                break
            fi
        done
        if [ -n "$H_SRC" ]; then
            cp -f "$H_SRC" "$HELPERS_STAGE/$helper" 2>/dev/null || true
            chmod +x "$HELPERS_STAGE/$helper" 2>/dev/null || true
            # Always install user copy
            cp -f "$HELPERS_STAGE/$helper" "$HOME/.local/share/hear2read/$helper" 2>/dev/null || true
            chmod 755 "$HOME/.local/share/hear2read/$helper" 2>/dev/null || true
            if [ "$HAS_ROOT" -eq 1 ]; then
                run_as_root cp -f "$HELPERS_STAGE/$helper" "/usr/share/hear2read/$helper"
                run_as_root chmod 755 "/usr/share/hear2read/$helper"
            fi
        fi
    done

    ln -sf "$HOME/.local/share/hear2read/uninstall_hear2read.sh" "$HOME/.local/bin/hear2read-uninstall" 2>/dev/null || true
    if [ "$HAS_ROOT" -eq 1 ]; then
        run_as_root ln -sf /usr/share/hear2read/uninstall_hear2read.sh /usr/local/bin/hear2read-uninstall
    fi

    # Create desktop launcher with universal fallback Exec commands
    TMP_DESKTOP="/tmp/hear2read-preferences.desktop"
    cat << 'DESKTOP_EOF' > "$TMP_DESKTOP"
[Desktop Entry]
Version=1.0
Type=Application
Name=Hear2Read Settings
GenericName=Speech Synthesizer Settings
Comment=Configure Hear2Read and eSpeak dual-engine routing for Orca
Exec=hear2read-manager
Icon=preferences-desktop-accessibility
Terminal=false
Categories=Settings;Accessibility;
StartupNotify=true
Keywords=speech;tts;orca;hear2read;espeak;synthesiser;malayalam;hindi;accessibility;settings;
DESKTOP_EOF

    # Ensure user-level binary wrapper exists so desktop entry always executes
    mkdir -p "$HOME/.local/bin" "$DESKTOP_DIR"
    cat << 'WRAPPER_EOF' > "$HOME/.local/bin/hear2read-manager"
#!/bin/sh
if [ -f "$HOME/.local/share/hear2read/hear2read_manager.py" ]; then
    exec python3 "$HOME/.local/share/hear2read/hear2read_manager.py" "$@"
elif [ -f /usr/share/hear2read/hear2read_manager.py ]; then
    exec python3 /usr/share/hear2read/hear2read_manager.py "$@"
elif [ -x /usr/local/bin/hear2read-manager ]; then
    exec /usr/local/bin/hear2read-manager "$@"
elif [ -x /usr/bin/hear2read-manager ]; then
    exec /usr/bin/hear2read-manager "$@"
fi
WRAPPER_EOF
    chmod +x "$HOME/.local/bin/hear2read-manager"

    # Install user desktop entry so application menu always indexes it
    cp -f "$TMP_DESKTOP" "$DESKTOP_DIR/hear2read-preferences.desktop"
    chmod 644 "$DESKTOP_DIR/hear2read-preferences.desktop"
    rm -f "$DESKTOP_DIR/hear2read-synthesiser.desktop" 2>/dev/null || true
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

    if [ "$HAS_ROOT" -eq 1 ]; then
        run_as_root mkdir -p /usr/share/applications /usr/local/bin /usr/bin
        run_as_root cp -f "$TMP_DESKTOP" /usr/share/applications/hear2read-preferences.desktop
        run_as_root rm -f /usr/share/applications/hear2read-synthesiser.desktop
        run_as_root chmod 644 /usr/share/applications/hear2read-preferences.desktop
        run_as_root rm -f /usr/local/bin/hear2read-manager /usr/bin/hear2read-manager
        run_as_root ln -sf /usr/share/hear2read/hear2read_manager.py /usr/local/bin/hear2read-manager
        run_as_root ln -sf /usr/share/hear2read/hear2read_manager.py /usr/bin/hear2read-manager
        run_as_root update-desktop-database /usr/share/applications 2>/dev/null || true
    fi

    # Clean up temporary staging files
    if [ "$HAS_ROOT" -eq 1 ]; then
        run_as_root rm -f "$TMP_CONF" "$TMP_DESKTOP" /tmp/hear2read_version.txt /tmp/speechd_tmp_*_$$.conf 2>/dev/null || true
        run_as_root rm -rf "$VOICES_STAGING" "$HELPERS_STAGE" 2>/dev/null || true
    fi

    # Finalize root operations (apply all queued system files and configurations)
    flush_root
    echo "LOG: System files, desktop menu and MIME database updated."

    echo "88"
    sleep 0.5

    # ==============================================================================
    # STEP 5: RESTART SPEECH DISPATCHER SERVICE & REFRESH ORCA
    # ==============================================================================
    echo "90"
    echo "# Step 5/6: Restarting Speech Dispatcher service..."
    echo "LOG: Terminating active Speech Dispatcher and sd_hear2read processes..."
    if command -v systemctl >/dev/null 2>&1; then
        timeout 3s systemctl --user stop speech-dispatcher.service 2>/dev/null || true
        timeout 3s systemctl --user stop speech-dispatcher.socket 2>/dev/null || true
    fi
    killall -9 sd_hear2read speech-dispatcher 2>/dev/null || true
    pkill -9 -f speech-dispatcher 2>/dev/null || true
    pkill -9 -f sd_hear2read 2>/dev/null || true

    # Remove any stale pid files, locks, or sockets that prevent Speech Dispatcher from starting
    local user_run="/run/user/$(id -u)/speech-dispatcher"
    if [ -d "$user_run" ]; then
        rm -rf "$user_run"/* 2>/dev/null || true
    fi

    # Ensure user override does not block /etc/speech-dispatcher/
    if [ -f "$HOME/.config/speech-dispatcher/speechd.conf" ]; then
        mv -f "$HOME/.config/speech-dispatcher/speechd.conf" "$HOME/.config/speech-dispatcher/speechd.conf.bak" 2>/dev/null || true
    fi

    echo "LOG: Starting Speech Dispatcher service..."
    if command -v systemctl >/dev/null 2>&1; then
        timeout 3s systemctl --user daemon-reload 2>/dev/null || true
        timeout 5s systemctl --user --no-block restart speech-dispatcher.socket 2>/dev/null || true
        timeout 5s systemctl --user --no-block restart speech-dispatcher.service 2>/dev/null || true
    fi

    # Fallback if socket is not bound
    sleep 0.5
    if [ ! -S "/run/user/$(id -u)/speech-dispatcher/speechd.sock" ]; then
        if command -v setsid >/dev/null 2>&1; then
            setsid speech-dispatcher -d </dev/null >/dev/null 2>&1 &
        else
            nohup speech-dispatcher -d </dev/null >/dev/null 2>&1 &
        fi
    fi

    # Wait 0.5 second for speech-dispatcher server socket to bind cleanly
    sleep 0.5

    if pgrep -f "[o]rca" >/dev/null 2>&1; then
        echo "LOG: Refreshing Orca screen reader connection..."
        if command -v systemd-run >/dev/null 2>&1; then
            systemd-run --user orca --replace >/dev/null 2>&1 || setsid orca --replace </dev/null >/dev/null 2>&1 &
        elif command -v setsid >/dev/null 2>&1; then
            setsid orca --replace </dev/null >/dev/null 2>&1 &
        else
            nohup orca --replace </dev/null >/dev/null 2>&1 &
        fi
    fi

    echo "LOG: Speech Dispatcher service restarted successfully."
    echo "95"
    sleep 0.5

    # ==============================================================================
    # STEP 6: SETUP COMPLETE & LAUNCH PREFERENCES
    # ==============================================================================
    # Final verification: ensure binary actually exists on disk
    if [ ! -f "/usr/lib/speech-dispatcher-modules/sd_hear2read" ]; then
        echo "ERROR: Core module binary /usr/lib/speech-dispatcher-modules/sd_hear2read was not installed."
        echo "LOG: Installation failed because system files could not be written."
        exit 1
    fi

    echo "100"
    echo "# Step 6/6: Setup complete! Launching Preferences Manager..."
    echo "LOG: Hear2Read Indic TTS setup finished successfully."
    echo "LOG: Dual-engine routing configured for Orca Screen Reader."
    echo "COMPLETE:INSTALLED:${DISCOVERED_LANGS[*]} | $DEFAULT_VOICE"
    sleep 1.0
}

# ==============================================================================
# RUN PIPELINE (WITH GTK3 PROGRESS DIALOG OR ZENITY FALLBACK)
# ==============================================================================
if [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; then
    if python3 -c "import gi; gi.require_version('Gtk', '3.0'); from gi.repository import Gtk" 2>/dev/null; then
        run_installation_pipeline | python3 "$PROGRESS_PY" "$PROGRESS_TITLE" "$PROGRESS_SUBTITLE"
    elif command -v zenity >/dev/null 2>&1; then
        run_installation_pipeline | zenity --progress \
            --title="$PROGRESS_TITLE" \
            --text="$PROGRESS_SUBTITLE" \
            --percentage=0 \
            --auto-close \
            --width=520
    else
        run_installation_pipeline
    fi
else
    run_installation_pipeline
fi

exit 0
