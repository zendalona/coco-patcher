#!/bin/bash

# ==============================================================================
# ROLLBACK & CLEANUP HANDLER
# ==============================================================================
INSTALLATION_SUCCESS=0
DOWNLOADED_MODEL=""
CREATED_SHORTCUTS=0
INSTALLED_LLAMA_SERVER=0

EXISTING_LAUNCHER=0
EXISTING_SHORTCUT=0

export PATH="$HOME/.local/bin:$PATH"

if [ -f "$HOME/AI_Models/launch_ai.sh" ];                          then EXISTING_LAUNCHER=1; fi
if [ -f "$HOME/.local/share/applications/Launch_AI.desktop" ];     then EXISTING_SHORTCUT=1; fi

cleanup() {
    if [ "$INSTALLATION_SUCCESS" -eq 1 ]; then return 0; fi
    echo -e "\n\n⚠️  INSTALLATION INTERRUPTED OR FAILED! Rolling back changes..."
    if [ "$CREATED_SHORTCUTS" -eq 1 ] && [ "$EXISTING_SHORTCUT" -eq 0 ]; then
        echo "🧹 Removing application menu entry..."
        rm -f "$HOME/.local/share/applications/Launch_AI.desktop"
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi
    if [ -n "$DOWNLOADED_MODEL" ] && [ -f "$DOWNLOADED_MODEL" ]; then
        echo "🧹 Removing incomplete model file: $DOWNLOADED_MODEL"
        rm -f "$DOWNLOADED_MODEL"
    fi
    if [ "$EXISTING_LAUNCHER" -eq 0 ] && [ -f "$HOME/AI_Models/launch_ai.sh" ]; then
        echo "🧹 Removing launcher script..."
        rm -f "$HOME/AI_Models/launch_ai.sh"
    fi
    if [ "$INSTALLED_LLAMA_SERVER" -eq 1 ]; then
        if [ "$NEEDS_LEGACY_LLAMA" -eq 1 ]; then
            echo "🧹 Removing static llama-server..."
            rm -f "$HOME/.local/bin/llama-server"
            rm -rf "$HOME/.local/lib/llama-server"
        else
            echo "🧹 Removing llama.cpp (via Homebrew)..."
            command -v brew &>/dev/null && brew uninstall llama.cpp 2>/dev/null || true
        fi
    fi
    echo "✅ Rollback complete. Your system has been restored."
    exit 1
}

trap cleanup INT TERM ERR HUP

# ==============================================================================
# HELPERS
# ==============================================================================
check_internet() {
    local CONTEXT="${1:-}"
    if ! curl -sf --max-time 5 https://huggingface.co > /dev/null 2>&1; then
        local MSG="Internet disconnected ${CONTEXT}. Please check your connection and try again."
        if command -v zenity &> /dev/null; then
            zenity --error --title="No Internet Connection" --text="$MSG" --ok-label="Close" --width=400 2>/dev/null || true
        fi
        echo "FATAL: $MSG"
        exit 1
    fi
}

# ==============================================================================
# GLIBC VERSION HELPER
# Returns 1 if system GLIBC is >= the required version, 0 otherwise.
# Usage: glibc_at_least 2 38
# ==============================================================================
glibc_at_least() {
    local req_major="$1" req_minor="$2"
    local glibc_str
    glibc_str=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
    if [ -z "$glibc_str" ]; then return 0; fi   # can't detect → assume OK
    local cur_major cur_minor
    cur_major=$(echo "$glibc_str" | cut -d. -f1)
    cur_minor=$(echo "$glibc_str" | cut -d. -f2)
    if [ "$cur_major" -gt "$req_major" ]; then return 0; fi
    if [ "$cur_major" -eq "$req_major" ] && [ "$cur_minor" -ge "$req_minor" ]; then return 0; fi
    return 1
}

# Detect once at the top so every step can use it
NEEDS_LEGACY_LLAMA=0
if ! glibc_at_least 2 38; then
    NEEDS_LEGACY_LLAMA=1
    GLIBC_VERSION=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo "unknown")
    echo "⚠️  System GLIBC $GLIBC_VERSION is older than 2.38 — will use static llama.cpp build."
fi

# ==============================================================================
# STEP 1: Basic tools
# ==============================================================================
echo "=== Starting Local AI Assistant Setup (llama.cpp Edition) ==="

if ! command -v zenity &>/dev/null || ! command -v curl &>/dev/null || ! command -v wget &>/dev/null || ! command -v wmctrl &>/dev/null; then
    sudo apt-get install -y curl wget zenity wmctrl
fi

if ! command -v python3 &>/dev/null; then
    sudo apt-get install -y python3 python3-pip
fi

FREE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
zenity --question \
    --title="System Resource Check" \
    --text="Disk Space Available: ${FREE_SPACE} Gigabytes.\n\nPlease ensure you have enough free space for the model you select.\n\nDo you want to continue with the setup?" \
    --width=450 --ok-label="Continue Setup" --cancel-label="Exit Setup" 2>/dev/null || exit 0

zenity --warning \
    --title="Important: Please Read Before Continuing" \
    --text="This installation will take a long time to complete depending on your network speed.\n\ you will be prompted to enter your system password \n\nPress OK to begin." \
    --ok-label="OK" --width=500 2>/dev/null || exit 0

# ==============================================================================
# STEP 2a: Install Homebrew (if not already installed)
# ==============================================================================
BREW_BIN=""
if command -v brew &>/dev/null; then
    BREW_BIN="$(command -v brew)"
elif [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
    BREW_BIN="/home/linuxbrew/.linuxbrew/bin/brew"
elif [ -f "$HOME/.linuxbrew/bin/brew" ]; then
    BREW_BIN="$HOME/.linuxbrew/bin/brew"
fi

if [ -z "$BREW_BIN" ]; then
    check_internet "before installing Homebrew"
    echo "🍺 Homebrew not found. Installing Homebrew..."

    sudo apt-get install -y build-essential procps file git 2>/dev/null || true

    echo "Downloading and installing Homebrew. This may take several minutes. Please wait. "
    echo "  Note: You may be prompted for your password during this step."

    # Run installer to a temp log so we can stream it AND still check exit status.
    # (Piping directly into `while read` masks the exit code via subshell.)
    BREW_INSTALL_LOG="$(mktemp)"
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        > "$BREW_INSTALL_LOG" 2>&1
    BREW_INSTALL_EXIT=$?

    # Stream the log to terminal with ANSI codes stripped for screen readers
    while IFS= read -r line; do
        clean=$(printf '%s' "$line" | sed 's/\x1B\[[0-9;]*[mK]//g')
        [ -n "$clean" ] && echo "  $clean"
    done < "$BREW_INSTALL_LOG"
    rm -f "$BREW_INSTALL_LOG"

    if [ $BREW_INSTALL_EXIT -ne 0 ]; then
        zenity --error --title="Homebrew Installation Failed" \
            --text="Homebrew could not be installed automatically.\n\nPlease install it manually from brew.sh" \
            --ok-label="Close" --width=400 2>/dev/null || true
        exit 1
    fi

    # Locate the brew binary just installed
    if [ -f "/home/linuxbrew/.linuxbrew/bin/brew" ]; then
        BREW_BIN="/home/linuxbrew/.linuxbrew/bin/brew"
    elif [ -f "$HOME/.linuxbrew/bin/brew" ]; then
        BREW_BIN="$HOME/.linuxbrew/bin/brew"
    else
        zenity --error --title="Homebrew Installation Failed" \
            --text="Homebrew could not be installed automatically.\n\nPlease install it manually from brew.sh" \
            --ok-label="Close" --width=400 2>/dev/null || true
        exit 1
    fi

    # Add Homebrew to PATH for this session using the bash-specific shellenv
    # (Homebrew on Linux now emits `brew shellenv bash` for bash sessions)
    eval "$("$BREW_BIN" shellenv bash 2>/dev/null || "$BREW_BIN" shellenv)"
    export PATH="$("$BREW_BIN" --prefix)/bin:$PATH"

    # Persist to shell RC file — write the bash-specific form so it works on login
    for SHELL_RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$SHELL_RC" ] && ! grep -q "brew shellenv" "$SHELL_RC" 2>/dev/null; then
            echo "" >> "$SHELL_RC"
            echo "# Homebrew" >> "$SHELL_RC"
            echo "eval \"\$($BREW_BIN shellenv bash)\"" >> "$SHELL_RC"
        fi
    done

   
else
   
    eval "$("$BREW_BIN" shellenv bash 2>/dev/null || "$BREW_BIN" shellenv)"
    export PATH="$("$BREW_BIN" --prefix)/bin:$PATH"
fi

# ==============================================================================
# STEP 2b: Install llama.cpp  (Homebrew for modern GLIBC; static build for older)
# ==============================================================================

# --- Path where we install the static binary fallback ---
LLAMA_LOCAL_BIN="$HOME/.local/bin/llama-server"

# Helper: download and unpack the latest llama.cpp static release from GitHub
install_llama_static() {
    echo "🔧 Installing llama.cpp "
    check_internet "before downloading llama.cpp"

    # Install dependencies (needed for source build fallback and runtime libgomp)
    echo "📦 Installing build dependencies..."
    sudo apt-get install -y build-essential cmake git libgomp1 tar 2>/dev/null || true

    # --- Detect CPU arch ---
    LLAMA_ARCH="x64"
    [ "$(uname -m)" = "aarch64" ] && LLAMA_ARCH="arm64"

    # --- Get latest release tag via HTTP redirect (no API rate-limit issues) ---
    # llama.cpp moved to ggml-org; try that first, fall back to ggerganov mirror
    LATEST_TAG=$(curl -sI "https://github.com/ggml-org/llama.cpp/releases/latest" \
        | grep -i '^location:' | grep -oE 'tag/[^ ]+' | cut -d/ -f2 | tr -d '[:space:]')
    if [ -z "$LATEST_TAG" ]; then
        LATEST_TAG=$(curl -sI "https://github.com/ggerganov/llama.cpp/releases/latest" \
            | grep -i '^location:' | grep -oE 'tag/[^ ]+' | cut -d/ -f2 | tr -d '[:space:]')
    fi

    if [ -n "$LATEST_TAG" ]; then
        # Releases now ship as .tar.gz (changed from .zip in mid-2025)
        LLAMA_TGZ_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LATEST_TAG}/llama-${LATEST_TAG}-bin-ubuntu-${LLAMA_ARCH}.tar.gz"
        LLAMA_TMP="$(mktemp -d)"
        echo "=== Downloading llama.cpp ${LATEST_TAG} for ubuntu-${LLAMA_ARCH}. Please wait. ==="
        if wget --show-progress -O "$LLAMA_TMP/llama.tar.gz" "$LLAMA_TGZ_URL" 2>&1; then
            tar -xzf "$LLAMA_TMP/llama.tar.gz" -C "$LLAMA_TMP/" 2>/dev/null
            FOUND_BIN=$(find "$LLAMA_TMP" -name "llama-server" -type f | head -1)
            if [ -n "$FOUND_BIN" ]; then
                # The release archive ships shared .so files alongside the binary.
                # We must keep them together — copy everything into a dedicated lib dir.
                LLAMA_INSTALL_DIR="$HOME/.local/lib/llama-server"
                mkdir -p "$LLAMA_INSTALL_DIR" "$HOME/.local/bin"

                # Copy the binary
                cp "$FOUND_BIN" "$LLAMA_INSTALL_DIR/llama-server"
                chmod +x "$LLAMA_INSTALL_DIR/llama-server"

                # Copy all bundled .so files
                find "$(dirname "$FOUND_BIN")" -name "*.so*" -exec cp -P {} "$LLAMA_INSTALL_DIR/" \;
                # Also copy any .so files from the archive root
                find "$LLAMA_TMP" -maxdepth 2 -name "*.so*" -exec cp -P {} "$LLAMA_INSTALL_DIR/" \; 2>/dev/null

                # Write a wrapper that sets LD_LIBRARY_PATH before exec
                cat > "$LLAMA_LOCAL_BIN" << WRAPPER_EOF
#!/bin/bash
export LD_LIBRARY_PATH="$LLAMA_INSTALL_DIR:\${LD_LIBRARY_PATH}"
exec "$LLAMA_INSTALL_DIR/llama-server" "\$@"
WRAPPER_EOF
                chmod +x "$LLAMA_LOCAL_BIN"
                rm -rf "$LLAMA_TMP"
                echo "✅ llama-server installed at: $LLAMA_INSTALL_DIR (wrapper: $LLAMA_LOCAL_BIN)"
                return 0
            fi
        fi
        rm -rf "$LLAMA_TMP"
        echo "⚠️  Pre-built binary download failed. Falling back to source build..."
    else
        echo "⚠️  Could not determine latest release tag. Falling back to source build..."
    fi

    # --- Source build fallback ---
    echo "⚙️  Building llama.cpp from source (10–20 minutes on most hardware)..."
    BUILD_DIR="$(mktemp -d)"
    echo "  Cloning repository..."
    git clone --depth=1 https://github.com/ggml-org/llama.cpp "$BUILD_DIR/llama.cpp" \
        || git clone --depth=1 https://github.com/ggerganov/llama.cpp "$BUILD_DIR/llama.cpp" \
        || { echo "ERROR: git clone of llama.cpp failed"; rm -rf "$BUILD_DIR"; return 1; }

    echo "  Configuring cmake..."
    cmake -S "$BUILD_DIR/llama.cpp" -B "$BUILD_DIR/build" \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_STATIC=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_SERVER=ON \
        > "$BUILD_DIR/cmake_configure.log" 2>&1

    echo "  Compiling with $(nproc) cores — please wait..."
    cmake --build "$BUILD_DIR/build" --config Release -j"$(nproc)" \
        > "$BUILD_DIR/cmake_build.log" 2>&1
    BUILD_EXIT=$?

    if [ $BUILD_EXIT -ne 0 ]; then
        echo "ERROR: Source build failed. Last 20 lines:"
        tail -20 "$BUILD_DIR/cmake_build.log"
        cp "$BUILD_DIR/cmake_build.log" /tmp/cmake_build.log 2>/dev/null
        rm -rf "$BUILD_DIR"
        zenity --error --title="Build Failed" \
            --text="Could not build llama.cpp from source.\n\nPlease upgrade to Ubuntu 22.04+ and try again.\nSee /tmp/cmake_build.log for details." \
            --ok-label="Close" --width=480 2>/dev/null || true
        return 1
    fi

    FOUND_BIN=$(find "$BUILD_DIR/build" \( -name "llama-server" -o -name "server" \) -type f | head -1)
    if [ -z "$FOUND_BIN" ]; then
        echo "ERROR: llama-server binary not found after build."
        rm -rf "$BUILD_DIR"; return 1
    fi

    # Install binary + all co-built .so files into a dedicated directory,
    # then create a wrapper that sets LD_LIBRARY_PATH at runtime.
    LLAMA_INSTALL_DIR="$HOME/.local/lib/llama-server"
    mkdir -p "$LLAMA_INSTALL_DIR" "$HOME/.local/bin"

    cp "$FOUND_BIN" "$LLAMA_INSTALL_DIR/llama-server"
    chmod +x "$LLAMA_INSTALL_DIR/llama-server"
    # Copy all .so files produced by the build
    find "$BUILD_DIR/build" -name "*.so*" -exec cp -P {} "$LLAMA_INSTALL_DIR/" \; 2>/dev/null

    cat > "$LLAMA_LOCAL_BIN" << WRAPPER_EOF
#!/bin/bash
export LD_LIBRARY_PATH="$LLAMA_INSTALL_DIR:\${LD_LIBRARY_PATH}"
exec "$LLAMA_INSTALL_DIR/llama-server" "\$@"
WRAPPER_EOF
    chmod +x "$LLAMA_LOCAL_BIN"
    cp "$BUILD_DIR/cmake_build.log" /tmp/cmake_build.log 2>/dev/null
    rm -rf "$BUILD_DIR"
    echo "✅ llama-server built and installed at: $LLAMA_INSTALL_DIR (wrapper: $LLAMA_LOCAL_BIN)"
}

LLAMA_SERVER_BIN=""

if [ "$NEEDS_LEGACY_LLAMA" -eq 0 ]; then
    # --- Modern system: use Homebrew ---
    BREW_LLAMA_BIN="$(brew --prefix 2>/dev/null)/bin/llama-server"
    if [ ! -f "$BREW_LLAMA_BIN" ]; then
        check_internet "before installing llama.cpp"
        echo "📦 Installing llama.cpp via Homebrew..."
        echo "=== Downloading llama.cpp. This may take several minutes. Please wait. ==="
        brew install llama.cpp 2>&1 | \
            while IFS= read -r line; do
                clean=$(printf '%s' "$line" | sed 's/\x1B\[[0-9;]*[mK]//g')
                [ -n "$clean" ] && echo "  $clean"
            done
        if [ ! -f "$BREW_LLAMA_BIN" ]; then
            zenity --error --title="Installation Failed" \
                --text="llama-server could not be installed via Homebrew. Please check your terminal for errors." \
                --ok-label="Close" --width=480 2>/dev/null || true
            exit 1
        fi
        INSTALLED_LLAMA_SERVER=1
    fi
    LLAMA_SERVER_BIN="$BREW_LLAMA_BIN"
    echo "✅ llama-server (Homebrew) at: $LLAMA_SERVER_BIN"
else
    # --- Legacy system: static binary ---
    # If existing wrapper is present but the actual binary is missing (broken install),
    # wipe and reinstall cleanly.
    if [ -f "$LLAMA_LOCAL_BIN" ] && [ ! -f "$HOME/.local/lib/llama-server/llama-server" ]; then
        echo "⚠️  Found broken llama-server wrapper (missing libs). Removing and reinstalling..."
        rm -f "$LLAMA_LOCAL_BIN"
        rm -rf "$HOME/.local/lib/llama-server"
    fi
    if [ ! -f "$LLAMA_LOCAL_BIN" ]; then
        install_llama_static || exit 1
        INSTALLED_LLAMA_SERVER=1
    else
        echo "✅ Static llama-server already installed at: $LLAMA_LOCAL_BIN"
    fi
    LLAMA_SERVER_BIN="$LLAMA_LOCAL_BIN"
fi

# ==============================================================================
# STEP 3: Model selection
# ==============================================================================
SELECTED=$(zenity --list --title="Select Your AI Engine" \
    --text="Choose the AI model you want to install." \
    --column="Model Name" --column="Estimated Size" \
    --print-column=1 --width=600 --height=200 \
    --ok-label="Select Model" --cancel-label="Cancel Setup" \
    "Llama 3.2 (3B - Super Fast)"  "~ 2.0 GB" \
    "✨ Paste Custom GGUF URL"     "Custom Size" \
    2>/dev/null)
if [ -z "$SELECTED" ]; then exit 0; fi

DIRECT_DOWNLOAD_URL=""

if [ "$SELECTED" = "Llama 3.2 (3B - Super Fast)" ]; then
    FILE_NAME="Llama-3.2-3B-Instruct-Q4_K_M.gguf"
    DIRECT_DOWNLOAD_URL="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
elif [ "$SELECTED" = "✨ Paste Custom GGUF URL" ]; then
    CUSTOM_INPUT=$(zenity --entry --title="Custom Download Link" \
        --text="How to get a link:\n1) Search Hugging Face GGUF models\n2) Choose any model\n3) Select 'Files and versions'\n4) Copy the download link of the .gguf file\n\nPaste the direct download URL below and press Enter:" \
        --ok-label="Download" --cancel-label="Cancel" --width=600 2>/dev/null)
    if [ -z "$CUSTOM_INPUT" ]; then exit 0; fi
    CUSTOM_INPUT=$(echo "$CUSTOM_INPUT" | tr -d '\r\n ')
    
    if [[ "$CUSTOM_INPUT" == *"huggingface.co"* && "$CUSTOM_INPUT" == *"/blob/"* ]]; then
        CUSTOM_INPUT="${CUSTOM_INPUT/\/blob\//\/resolve\/}"
    fi
    EXTRACTED_NAME=$(basename "$CUSTOM_INPUT" | cut -d'?' -f1)
    if [[ ! "$CUSTOM_INPUT" =~ ^https?:// ]] || [[ "$EXTRACTED_NAME" != *.gguf ]]; then
        zenity --error --title="Invalid Model Link" \
            --text="The URL you entered is not a valid GGUF model link.\n\nPlease paste a direct download URL ending in .gguf\n(e.g. https://huggingface.co/.../model.gguf)" \
            --ok-label="Close" --width=480 2>/dev/null || true
        exit 0
    fi
    FILE_NAME="${EXTRACTED_NAME%.gguf}.gguf"
    DIRECT_DOWNLOAD_URL="$CUSTOM_INPUT"
fi

DEST_DIR="$HOME/AI_Models"
WEB_DIR="$DEST_DIR/web_ui"
FILE_PATH="$DEST_DIR/$FILE_NAME"
mkdir -p "$DEST_DIR" "$WEB_DIR"

# ==============================================================================
# STEP 4: Download model execution (Pure wget)
# ==============================================================================
if [ ! -f "$FILE_PATH" ]; then
    check_internet "before downloading AI model"
    echo "=================================================================="
    echo "⬇️  DOWNLOADING: $FILE_NAME"
    echo "=================================================================="
    DOWNLOADED_MODEL="$FILE_PATH"

    echo "Direct fetching via URL: $DIRECT_DOWNLOAD_URL"
    wget --show-progress -O "$FILE_PATH" "$DIRECT_DOWNLOAD_URL"
fi

# ==============================================================================
# STEP 5: Write the accessible web UI (index.html)
# ==============================================================================
echo "🌐 Writing accessible web UI..."

cat > "$WEB_DIR/index.html" << 'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>Local LLM</title>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin/>
<link href="https://fonts.googleapis.com/css2?family=Cinzel:wght@400;600;700&family=Crimson+Pro:ital,wght@0,300;0,400;1,300&display=swap" rel="stylesheet"/>
<style>
/* ── Reset ──────────────────────────────────────────────── */
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;
  overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}

/* ── Tokens ─────────────────────────────────────────────── */
:root{
  --obsidian:#07090a;
  --deep:#0c1014;
  --surface:#111820;
  --surface2:#16202c;
  --border:rgba(180,140,60,0.18);
  --border-bright:rgba(210,170,80,0.45);
  --gold:#d4a843;
  --gold2:#f0c96a;
  --gold-dim:rgba(212,168,67,0.55);
  --amber:#b8860b;
  --teal:#2dd4bf;
  --text:#e8e4d8;
  --text-muted:#8a8070;
  --user-bg:rgba(20,35,55,0.7);
  --user-border:rgba(45,212,191,0.4);
  --ai-bg:rgba(15,22,18,0.75);
  --ai-border:rgba(212,168,67,0.5);
  --error-bg:rgba(40,12,12,0.8);
  --error-border:rgba(200,60,60,0.5);
  --glow:rgba(212,168,67,0.12);
  --glow2:rgba(45,212,191,0.08);
  --r:14px;
  --font-display:'Cinzel',serif;
  --font-body:'Crimson Pro',Georgia,serif;
  --font-ui:'Courier New',monospace;
  --fz:1.1rem;--lh:1.85;
}

/* ── Canvas ─────────────────────────────────────────────── */
html,body{height:100%;background:var(--obsidian);color:var(--text);
  font-family:var(--font-body);font-size:var(--fz);line-height:var(--lh);
  overflow-x:hidden}
body{display:flex;flex-direction:column;align-items:center;min-height:100vh;
  padding:0 1rem 1.5rem;position:relative}

/* ── Background orbs ────────────────────────────────────── */
body::before,body::after,.orb3{content:'';position:fixed;border-radius:50%;
  pointer-events:none;z-index:0;filter:blur(80px);opacity:.35}
body::before{width:520px;height:520px;
  background:radial-gradient(circle,rgba(180,130,30,.55),transparent 70%);
  top:-120px;right:-80px;animation:driftA 22s ease-in-out infinite alternate}
body::after{width:400px;height:400px;
  background:radial-gradient(circle,rgba(20,160,140,.4),transparent 70%);
  bottom:-80px;left:-60px;animation:driftB 28s ease-in-out infinite alternate}
.orb3{width:300px;height:300px;
  background:radial-gradient(circle,rgba(120,80,200,.25),transparent 70%);
  top:40%;left:55%;animation:driftC 35s ease-in-out infinite alternate}
@keyframes driftA{0%{transform:translate(0,0) scale(1)}100%{transform:translate(-40px,60px) scale(1.15)}}
@keyframes driftB{0%{transform:translate(0,0) scale(1)}100%{transform:translate(50px,-40px) scale(1.2)}}
@keyframes driftC{0%{transform:translate(0,0) scale(1)}100%{transform:translate(-30px,50px) scale(.9)}}

/* ── Noise grain overlay ────────────────────────────────── */
body>.grain{position:fixed;inset:0;pointer-events:none;z-index:1;opacity:.025;
  background-image:url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
  background-size:200px 200px}

/* ── Layout wrapper ─────────────────────────────────────── */
.shell{position:relative;z-index:2;width:100%;max-width:880px;
  display:flex;flex-direction:column;flex:1;gap:0;padding-top:1.4rem}

/* ── Header ─────────────────────────────────────────────── */
.hdr{display:flex;align-items:center;gap:1.1rem;padding-bottom:1.2rem;
  border-bottom:1px solid var(--border);margin-bottom:1.2rem;
  animation:fadeDown .7s ease both}
@keyframes fadeDown{from{opacity:0;transform:translateY(-14px)}to{opacity:1;transform:none}}
.hdr-logo{width:52px;height:52px;border-radius:10px;object-fit:contain;
  filter:drop-shadow(0 0 10px rgba(212,168,67,.5));flex-shrink:0;
  transition:filter .3s}
.hdr-logo:hover{filter:drop-shadow(0 0 18px rgba(212,168,67,.85))}
.hdr-text{}
.hdr-title{font-family:var(--font-display);font-size:1.35rem;font-weight:700;
  letter-spacing:.18em;color:var(--gold2);line-height:1;
  text-shadow:0 0 24px rgba(212,168,67,.4)}
.hdr-sub{font-family:var(--font-ui);font-size:.72rem;letter-spacing:.32em;
  color:var(--gold-dim);margin-top:.28rem;text-transform:uppercase}
.hdr-right{margin-left:auto;display:flex;flex-direction:column;align-items:flex-end;gap:.3rem}
.status-pill{display:flex;align-items:center;gap:.45rem;
  background:rgba(255,255,255,.04);border:1px solid var(--border);
  border-radius:999px;padding:.3rem .8rem;font-family:var(--font-ui);font-size:.75rem;
  color:var(--text-muted);transition:border-color .3s}home/hari/.local/bin/llama-server: error while loading shared libraries: libllama-server-impl.so: cannot open shared object file: No such file or directory

.status-pill.online{border-color:rgba(45,212,191,.4);color:var(--teal)}
.status-pill.offline{border-color:rgba(200,60,60,.4);color:#e07070}
.status-dot{width:7px;height:7px;border-radius:50%;background:currentColor;flex-shrink:0;
  box-shadow:0 0 6px currentColor}
.status-dot.pulse{animation:statusPulse 2s ease-in-out infinite}
@keyframes statusPulse{0%,100%{opacity:1}50%{opacity:.35}}

/* ── Divider line with glow ─────────────────────────────── */
.glow-line{height:1px;background:linear-gradient(90deg,transparent,var(--gold-dim),transparent);
  margin-bottom:1.2rem;opacity:.6}

/* ── Chat log ───────────────────────────────────────────── */
#chat-log{flex:1;min-height:280px;max-height:58vh;overflow-y:auto;
  border:1px solid var(--border);border-radius:var(--r);padding:1.4rem;
  background:linear-gradient(160deg,var(--surface),var(--deep) 80%);
  scroll-behavior:smooth;backdrop-filter:blur(6px);
  box-shadow:inset 0 1px 0 rgba(255,255,255,.04),0 0 40px rgba(0,0,0,.6)}
#chat-log::-webkit-scrollbar{width:5px}
#chat-log::-webkit-scrollbar-track{background:transparent}
#chat-log::-webkit-scrollbar-thumb{background:rgba(212,168,67,.25);border-radius:3px}
#chat-log::-webkit-scrollbar-thumb:hover{background:rgba(212,168,67,.5)}
#chat-log:empty::before{
  content:"Ask me anything. I run entirely on your device.";
  display:block;text-align:center;padding:3rem 1rem;
  color:var(--text-muted);font-style:italic;font-size:1rem;
  background:radial-gradient(ellipse at center,rgba(212,168,67,.04) 0%,transparent 70%)}

/* ── Messages ───────────────────────────────────────────── */
.message{margin-bottom:1.3rem;padding:1.05rem 1.3rem;border-radius:var(--r);
  border-left:3px solid transparent;font-size:var(--fz);
  line-height:var(--lh);word-break:break-word;position:relative;
  animation:msgIn .35s cubic-bezier(.22,1,.36,1) both}
@keyframes msgIn{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
.message:last-child{margin-bottom:0}
.msg-role{font-family:var(--font-ui);font-size:.7rem;letter-spacing:.18em;
  text-transform:uppercase;margin-bottom:.5rem;opacity:.6}
.message.user{background:var(--user-bg);border-left-color:var(--user-border);
  backdrop-filter:blur(4px);
  box-shadow:0 2px 18px rgba(0,0,0,.35),-4px 0 0 rgba(45,212,191,.12)}
.message.user .msg-role{color:var(--teal)}
.message.ai{background:var(--ai-bg);border-left-color:var(--ai-border);
  backdrop-filter:blur(4px);
  box-shadow:0 2px 18px rgba(0,0,0,.35),-4px 0 0 rgba(212,168,67,.12)}
.message.ai .msg-role{color:var(--gold)}
.message.error{background:var(--error-bg);border-left-color:var(--error-border)}
.message.error .msg-role{color:#e07070}
.message p+p{margin-top:.55rem}
.msg-body p{margin-bottom:.5rem}
.msg-body p:last-child{margin-bottom:0}
.msg-body h3{font-family:var(--font-display);font-size:1rem;font-weight:600;
  letter-spacing:.08em;color:var(--gold2);margin:1rem 0 .4rem;line-height:1.3}
.msg-body h4{font-family:var(--font-display);font-size:.9rem;font-weight:600;
  color:var(--gold-dim);margin:.8rem 0 .3rem;line-height:1.3}
.msg-body ul,.msg-body ol{padding-left:1.4rem;margin:.4rem 0 .6rem}
.msg-body li{margin-bottom:.3rem;line-height:var(--lh)}
.msg-body ul li{list-style:disc}
.msg-body ol li{list-style:decimal}
.msg-body strong{font-weight:700;color:var(--text)}
.msg-body em{font-style:italic;color:var(--text-muted)}
.msg-body code{font-family:var(--font-ui);font-size:.88em;
  background:rgba(212,168,67,.1);color:var(--gold2);
  padding:.1em .35em;border-radius:4px;border:1px solid rgba(212,168,67,.18)}
.msg-body pre{background:rgba(0,0,0,.45);border:1px solid var(--border);
  border-radius:8px;padding:.85rem 1rem;overflow-x:auto;margin:.6rem 0}
.msg-body pre code{background:none;border:none;padding:0;
  color:#c8e6b0;font-size:.85rem;line-height:1.65}

/* ── Thinking indicator ─────────────────────────────────── */
#thinking{display:none;margin-bottom:1.3rem;padding:1.05rem 1.3rem;
  border-radius:var(--r);background:var(--ai-bg);border-left:3px solid var(--ai-border);
  backdrop-filter:blur(4px);box-shadow:0 2px 18px rgba(0,0,0,.35)}
#thinking .msg-role{font-family:var(--font-ui);font-size:.7rem;letter-spacing:.18em;
  text-transform:uppercase;margin-bottom:.5rem;color:var(--gold);opacity:.6}
.thinking-dots{display:flex;gap:5px;align-items:center;padding:.2rem 0}
.thinking-dots span{width:7px;height:7px;border-radius:50%;
  background:var(--gold-dim);display:inline-block}
.thinking-dots span:nth-child(1){animation:bounce 1.2s .0s ease-in-out infinite}
.thinking-dots span:nth-child(2){animation:bounce 1.2s .2s ease-in-out infinite}
.thinking-dots span:nth-child(3){animation:bounce 1.2s .4s ease-in-out infinite}
@keyframes bounce{0%,80%,100%{transform:translateY(0);opacity:.4}40%{transform:translateY(-6px);opacity:1}}

/* ── Input area ─────────────────────────────────────────── */
.input-area{display:flex;flex-direction:column;gap:.8rem;margin-top:1rem}
.textarea-wrap{position:relative;border:1px solid var(--border);border-radius:var(--r);
  background:linear-gradient(135deg,var(--surface),var(--surface2));
  transition:border-color .25s,box-shadow .25s;overflow:hidden}
.textarea-wrap::before{content:'';position:absolute;inset:0;border-radius:inherit;
  background:linear-gradient(135deg,rgba(212,168,67,.04),rgba(45,212,191,.02));
  pointer-events:none}
.textarea-wrap:focus-within{border-color:var(--border-bright);
  box-shadow:0 0 0 3px rgba(212,168,67,.08),0 0 30px rgba(212,168,67,.06)}
#user-input{width:100%;min-height:88px;max-height:240px;resize:vertical;
  background:transparent;border:none;outline:none;color:var(--text);
  font-family:var(--font-body);font-size:var(--fz);line-height:var(--lh);
  padding:.95rem 1.1rem;caret-color:var(--gold);position:relative;z-index:1}
#user-input::placeholder{color:rgba(138,128,112,.45)}

/* ── Buttons ────────────────────────────────────────────── */
.buttons{display:flex;gap:.75rem;flex-wrap:wrap}
button{font-family:var(--font-display);font-size:.82rem;letter-spacing:.12em;
  padding:.72rem 1.5rem;border-radius:var(--r);border:1px solid transparent;
  cursor:pointer;transition:all .2s;text-transform:uppercase;font-weight:600;
  position:relative;overflow:hidden}
button::after{content:'';position:absolute;inset:0;background:linear-gradient(rgba(255,255,255,.06),transparent);
  opacity:0;transition:opacity .2s}
button:hover::after{opacity:1}
button:focus-visible{outline:2px solid var(--gold);outline-offset:3px}
#send-btn{background:linear-gradient(135deg,var(--amber),var(--gold));
  color:#0a0800;font-weight:700;flex:1;min-width:130px;
  box-shadow:0 4px 20px rgba(212,168,67,.25);
  border-color:rgba(212,168,67,.3)}
#send-btn:hover:not(:disabled){background:linear-gradient(135deg,var(--gold),var(--gold2));
  box-shadow:0 6px 28px rgba(212,168,67,.4);transform:translateY(-1px)}
#send-btn:active{transform:translateY(0)}
#send-btn:disabled{opacity:.4;cursor:not-allowed;transform:none}
#stop-btn{background:rgba(40,10,10,.6);color:#e07070;
  border-color:rgba(200,60,60,.35);min-width:90px;display:none}
#stop-btn:hover{background:rgba(60,15,15,.8);border-color:rgba(220,80,80,.6);color:#f09090}
#clear-btn{background:rgba(255,255,255,.03);color:var(--text-muted);
  border-color:var(--border);min-width:90px}
#clear-btn:hover{border-color:rgba(138,128,112,.45);color:var(--text)}
#close-btn{background:rgba(255,255,255,.03);color:var(--text-muted);
  border-color:var(--border);min-width:90px}
#close-btn:hover{border-color:rgba(200,60,60,.45);color:#e07070}

/* ── Footer ─────────────────────────────────────────────── */
.ftr{margin-top:1.4rem;padding-top:.9rem;
  border-top:1px solid var(--border);
  font-family:var(--font-ui);font-size:.72rem;color:var(--text-muted);
  text-align:center;display:flex;flex-direction:column;gap:.25rem;opacity:.7}
.ftr a{color:var(--gold-dim);text-decoration:none;transition:color .2s}
.ftr a:hover{color:var(--gold)}

.message:focus{outline:2px solid var(--gold);outline-offset:2px}
.message:focus-visible{outline:2px solid var(--gold);outline-offset:2px}

/* ── Page entry animation ───────────────────────────────── */
.shell{animation:shellIn .55s cubic-bezier(.22,1,.36,1) both}
@keyframes shellIn{from{opacity:0;transform:translateY(20px)}to{opacity:1;transform:none}}
</style>
</head>
<body>
<div class="orb3" aria-hidden="true"></div>
<div class="grain" aria-hidden="true"></div>
<!-- sr-announcer lives OUTSIDE role=application so live regions still fire -->
<div id="sr-announcer"      aria-live="assertive" aria-atomic="true" class="sr-only"></div>
<!-- separate region for user-sent announcements so it never races with AI status -->
<div id="sr-user-announcer" aria-live="polite"    aria-atomic="true" class="sr-only"></div>

<div class="shell" role="application" aria-label="Zendalona Local LLM">

  <!-- Header -->
  <header class="hdr">
    <img class="hdr-logo"
         src="https://i0.wp.com/zendalona.com/wp-content/uploads/2025/11/zenda-backgr-logo.png?w=512&ssl=1"
         alt="Zendalona logo"
         onerror="this.style.display='none'"/>
    <div class="hdr-text">
      <div class="hdr-title" aria-label="Zendalona">ZENDALONA</div>
      <div class="hdr-sub">Vision Beyond Sight</div>
    </div>
    <div class="hdr-right">
      <div class="status-pill" id="status-pill">
        <span class="status-dot pulse" id="status-dot" aria-hidden="true"></span>
        <span id="status-text">Connecting…</span>
      </div>
    </div>
  </header>

  <div class="glow-line" aria-hidden="true"></div>

  <!-- Conversation -->
  <main>
    <div id="chat-log"
         aria-label="Conversation history. Each message is focusable with Tab."
         tabindex="0"></div>

    <div id="thinking" aria-live="assertive" aria-atomic="true" aria-label="Local LLM is thinking" style="display:none">
      <div class="msg-role" aria-hidden="true">Local LLM</div>
      <div class="thinking-dots" aria-hidden="true">
        <span></span><span></span><span></span>
      </div>
    </div>

    <!-- Input -->
    <div class="input-area">
      <label for="user-input" class="sr-only">Type your message</label>
      <div class="textarea-wrap">
        <textarea id="user-input"
          rows="3"
          placeholder="Ask me anything…"
          aria-required="true"
          autocomplete="off"
          spellcheck="true"></textarea>
      </div>
      <div class="buttons">
        <button id="send-btn" type="button" aria-label="Send message">Send</button>
        <button id="stop-btn" type="button" aria-label="Stop generating">Stop</button>
        <button id="clear-btn" type="button" aria-label="Clear conversation">Clear</button>
        <button id="close-btn" type="button" aria-label="Close this tab">Close</button>
      </div>
    </div>
  </main>

  <!-- Footer -->
  <footer class="ftr">
    <span>All processing is local — your words never leave this device.</span>
    <span>Powered by <a href="https://zendalona.com" target="_blank" rel="noopener">zendalona.com</a></span>
  </footer>

</div><!-- .shell -->

<script>
(function(){
"use strict";
const log      = document.getElementById("chat-log"),
      input    = document.getElementById("user-input"),
      sendBtn  = document.getElementById("send-btn"),
      stopBtn  = document.getElementById("stop-btn"),
      clearBtn = document.getElementById("clear-btn"),
      closeBtn = document.getElementById("close-btn"),
      thinking = document.getElementById("thinking"),
      statusPill = document.getElementById("status-pill"),
      statusDot  = document.getElementById("status-dot"),
      statusText = document.getElementById("status-text"),
      sr         = document.getElementById("sr-announcer"),
      srUser     = document.getElementById("sr-user-announcer");

const history = [];
let loadingInterval = null, loadingIdx = 0, busy = false, currentAbort = null;
let userIsTyping = false, typingTimer = null;

// Track whether the user is actively typing so speak() and DOM updates
// never fire a live-region announcement that pulls focus away mid-keystroke.
input.addEventListener("keydown", (e) => {
  userIsTyping = true;
  clearTimeout(typingTimer);
  typingTimer = setTimeout(() => { userIsTyping = false; }, 1000);
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});

// Safety net: if focus escapes to anywhere other than buttons/log while
// the user is typing, yank it back to the textarea immediately.
document.addEventListener("keydown", (e) => {
  if (busy) return; // during AI response, don't interfere
  const active = document.activeElement;
  if (active === input || active === sendBtn || active === stopBtn || active === clearBtn || active === closeBtn || active === log) return;
  // A printable character or Space was pressed and focus is somewhere unexpected
  if (e.key.length === 1 || e.key === "Backspace" || e.key === "Delete") {
    e.preventDefault();
    input.focus();
    // Re-dispatch the key so the character still lands in the textarea
    input.dispatchEvent(new KeyboardEvent("keydown", { key: e.key, bubbles: false }));
  }
}, true); // capture phase so we intercept before the element handles it

const loadingMessages = [
  "Local LLM is thinking. Please wait.",
  "Still processing your question.",
  "Working on your answer. Almost there.",
  "Taking a moment for complex questions.",
  "Preparing your response .",
];

// speak() targets the assertive region — used for AI status updates.
function speak(msg) {
  if (userIsTyping) return;
  sr.textContent = "";
  requestAnimationFrame(() => { sr.textContent = msg; });
}

// announceUser() targets a separate polite region so it never races with speak().
// It clears the node, waits one frame for the DOM mutation to register,
// then sets the text — giving Orca a clean edge to latch onto.
function announceUser(msg) {
  srUser.textContent = "";
  requestAnimationFrame(() => { srUser.textContent = msg; });
}

async function checkStatus() {
  try {
    const r = await fetch("/api/health", { signal: AbortSignal.timeout(4000) });
    if (r.ok) {
      statusPill.className = "status-pill online";
      statusDot.className  = "status-dot";
      statusText.textContent = "Model ready";
    } else throw new Error();
  } catch {
    statusPill.className = "status-pill offline";
    statusDot.className  = "status-dot";
    statusText.textContent = "Model offline";
  }
}

function startLoading() {
  loadingIdx = 0;
  thinking.style.display = "block";
  stopBtn.style.display = "inline-block";
  speak(loadingMessages[0]);
  loadingInterval = setInterval(() => {
    loadingIdx = (loadingIdx + 1) % loadingMessages.length;
    speak(loadingMessages[loadingIdx]);
  }, 7000);
}

function stopLoading() {
  clearInterval(loadingInterval);
  loadingInterval = null;
  thinking.style.display = "none";
}

function renderInline(raw) {
  return raw
    .replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")
    .replace(/`([^`]+)`/g,"<code>$1</code>")
    .replace(/\*\*\*(.+?)\*\*\*/g,"<strong><em>$1</em></strong>")
    .replace(/\*\*(.+?)\*\*/g,"<strong>$1</strong>")
    .replace(/\*(.+?)\*/g,"<em>$1</em>")
    .replace(/__(.*?)__/g,"<strong>$1</strong>")
    .replace(/_([^_]+)_/g,"<em>$1</em>");
}

function renderMarkdown(text) {
  const lines = text.split("\n");
  const out = [];
  let inUL = false, inOL = false, inCode = false, codeBuf = [];

  function closeList() {
    if (inUL) { out.push("</ul>"); inUL = false; }
    if (inOL) { out.push("</ol>"); inOL = false; }
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (line.startsWith("```")) {
      if (!inCode) {
        closeList();
        inCode = true; codeBuf = [];
      } else {
        out.push("<pre><code>" + codeBuf.map(l =>
          l.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")
        ).join("\n") + "</code></pre>");
        inCode = false; codeBuf = [];
      }
      continue;
    }
    if (inCode) { codeBuf.push(line); continue; }

    if (/^#{1,6}\s/.test(line)) {
      closeList();
      const lvl = line.match(/^(#+)/)[1].length;
      const t = renderInline(line.replace(/^#+\s+/, ""));
      const tag = lvl <= 2 ? "h3" : "h4";
      out.push(`<${tag}>${t}</${tag}>`);
      continue;
    }

    if (/^(\*|-|•)\s+/.test(line)) {
      if (!inUL) { closeList(); out.push("<ul>"); inUL = true; }
      out.push("<li>" + renderInline(line.replace(/^(\*|-|•)\s+/, "")) + "</li>");
      continue;
    }
    if (/^\d+\.\s+/.test(line)) {
      if (!inOL) { closeList(); out.push("<ol>"); inOL = true; }
      out.push("<li>" + renderInline(line.replace(/^\d+\.\s+/, "")) + "</li>");
      continue;
    }

    closeList();
    if (line.trim() === "") {
      out.push("<br>");
    } else {
      out.push("<p>" + renderInline(line) + "</p>");
    }
  }
  closeList();
  if (inCode && codeBuf.length) {
    out.push("<pre><code>" + codeBuf.map(l =>
      l.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")
    ).join("\n") + "</code></pre>");
  }
  return out.join("");
}

function appendMessage(role, text) {
  const wrap = document.createElement("div");
  wrap.className = "message " + role;
  // tabindex="0" makes each message reachable by Tab so users can
  // revisit history. No role="article" — that causes Orca/NVDA to
  // append the word "article" after every announcement.
  wrap.setAttribute("tabindex", "0");
  const roleLabel = role === "user" ? "You said" : role === "ai" ? "Local LLM replied" : "Error";
  // aria-label on the wrapper gives the SR a single clean string to read.
  wrap.setAttribute("aria-label", roleLabel + ": " + text);

  const roleDiv = document.createElement("div");
  roleDiv.className = "msg-role";
  roleDiv.setAttribute("aria-hidden", "true");
  roleDiv.textContent = role === "user" ? "You" : role === "ai" ? "Local LLM" : "Error";
  wrap.appendChild(roleDiv);

  // aria-hidden on msg-body prevents the SR from reading the rendered
  // HTML a second time after already reading the aria-label above.
  const body = document.createElement("div");
  body.className = "msg-body";
  body.setAttribute("aria-hidden", "true");
  body.innerHTML = renderMarkdown(text);
  wrap.appendChild(body);

  log.appendChild(wrap);
  log.scrollTop = log.scrollHeight;
}

function restoreFocus() {
  // Called only after the SR live-region announcement is fully queued.
  // We wait 1200 ms so Orca has finished speaking the reply before focus moves.
  // Focus moves silently — the textarea label ("Type your message") is what
  // the SR will announce, giving the user a clear cue they can type again.
  setTimeout(() => {
    if (!input.disabled && input.getAttribute("aria-disabled") !== "true") {
      input.focus();
    }
  }, 1200);
}

function resetUI() {
  // Only responsible for re-enabling controls. Focus is handled separately
  // by each outcome path so it never races with the live-region announcement.
  busy = false;
  currentAbort = null;
  sendBtn.disabled = false;
  sendBtn.textContent = "Send";
  stopBtn.style.display = "none";
  input.disabled = false;
  input.removeAttribute("aria-disabled");
}

function stripSpecialTokens(text) {
  // Remove <think>...</think> blocks (including multiline) from reasoning models
  text = text.replace(/<think>[\s\S]*?<\/think>/gi, "");
  // Remove angle-bracket special tokens: <eot_id>, <|end|>, <|im_end|>, <s>, </s>, etc.
  text = text.replace(/<\|?[a-zA-Z0-9_]+\|?>/g, "");
  // Remove bracket tokens: [INST], [/INST], <<SYS>>, <</SYS>>
  text = text.replace(/\[\/?(INST|SYS|s)\]|<<\/?(SYS|INST)>>/g, "");
  return text.trim();
}

async function sendMessage() {
  const text = input.value.trim();
  if (!text || busy) return;

  busy = true;
  currentAbort = new AbortController();
  sendBtn.disabled = true;
  sendBtn.textContent = "Sending…";
  stopBtn.style.display = "inline-block";
  input.disabled = true;
  input.setAttribute("aria-disabled", "true");

  appendMessage("user", text);
  history.push({ role: "user", content: text });
  input.value = "";

  // Announce via the dedicated polite region — never races with the assertive AI-status region.
  announceUser("User asked: " + text);

  // Wait long enough for Orca to finish reading before the assertive "AI is thinking" fires.
  await new Promise(res => setTimeout(res, 1500));

  startLoading();

  try {
    const r = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messages: history, stream: false, max_tokens: 1024, temperature: 0.7 }),
      signal: currentAbort.signal
    });
    if (!r.ok) { const e = await r.text(); throw new Error("Server error " + r.status + ": " + e); }
    const data = await r.json();
    const raw = (data?.choices?.[0]?.message?.content || "").trim();
    const reply = stripSpecialTokens(raw) || "No response received.";
    history.push({ role: "assistant", content: reply });
    stopLoading();
    appendMessage("ai", reply);
    resetUI();
    // Speak AFTER resetUI so input is already re-enabled when the 1200 ms timer fires.
    speak("AI replied: " + reply);
    restoreFocus();
  } catch(err) {
    stopLoading();
    resetUI();
    if (err.name === "AbortError") {
      history.pop();
      appendMessage("error", "Response stopped.");
      speak("Response stopped.");
    } else {
      const msg = "Error: Could not get a response. " + err.message;
      appendMessage("error", msg);
      speak(msg);
    }
    restoreFocus();
  }
}

function stopGeneration() {
  if (currentAbort) {
    currentAbort.abort();
    speak("Stopping response.");
  }
}

function clearChat() {
  history.length = 0;
  log.innerHTML = "";
  speak("Conversation cleared.");
  input.focus();
}

sendBtn.addEventListener("click", sendMessage);
stopBtn.addEventListener("click", stopGeneration);
clearBtn.addEventListener("click", clearChat);
closeBtn.addEventListener("click", () => {
  // Fire-and-forget: tells ai_server.py to shut itself down, which lets the
  // launcher script in the terminal detect the exit and quit automatically
  // instead of waiting on a manual Ctrl+C. sendBeacon is used (rather than
  // fetch) because it's designed to survive the page closing right after.
  try { navigator.sendBeacon("/api/shutdown"); } catch (e) {}
  window.close();
});

checkStatus();
input.focus();
})();
</script>
</body>
</html>
HTML_EOF

# ==============================================================================
# STEP 6: Write the Python proxy server (ai_server.py)
# ==============================================================================
echo "🐍 Writing Python server..."

cat > "$WEB_DIR/ai_server.py" << 'PY_EOF'
#!/usr/bin/env python3
import http.server, json, sys, threading, urllib.request, urllib.error
from pathlib import Path

WEB_PORT         = 8000
LLAMA_SERVER_URL = "http://127.0.0.1:8080/v1/chat/completions"
HEALTH_URL       = "http://127.0.0.1:8080/v1/models"
HTML_FILE        = Path(__file__).parent / "index.html"

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass

    def do_GET(self):
        if self.path in ("/", "/index.html"): self._serve_html()
        elif self.path == "/api/health":       self._health()
        else:                                  self._json(404, {"error": "Not found."})

    def do_POST(self):
        if self.path == "/api/chat":     self._chat()
        elif self.path == "/api/shutdown": self._shutdown()
        else:                             self._json(404, {"error": "Not found."})

    def _serve_html(self):
        try:    html = HTML_FILE.read_bytes()
        except: self._json(500, {"error": "index.html missing."}); return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers()
        self.wfile.write(html)

    def _health(self):
        try:
            with urllib.request.urlopen(HEALTH_URL, timeout=3): pass
            self._json(200, {"status": "ok"})
        except: self._json(503, {"status": "offline"})

    def _chat(self):
        length = int(self.headers.get("Content-Length", 0))
        if not length: self._json(400, {"error": "Empty body."}); return
        try:    body = json.loads(self.rfile.read(length))
        except: self._json(400, {"error": "Invalid JSON."}); return
        payload = json.dumps({
            "messages":    body.get("messages", []),
            "stream":      False,
            "max_tokens":  body.get("max_tokens", 1024),
            "temperature": body.get("temperature", 0.7),
        }).encode()
        try:
            req = urllib.request.Request(
                LLAMA_SERVER_URL, data=payload,
                headers={"Content-Type": "application/json",
                         "Content-Length": str(len(payload))},
                method="POST")
            with urllib.request.urlopen(req, timeout=1000) as r: raw = r.read()
        except urllib.error.URLError as e:
            self._json(502, {"error": "Cannot reach llama-server: " + str(e.reason)}); return
        except Exception as e:
            self._json(500, {"error": str(e)}); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _shutdown(self):
        # Acknowledge first, then stop serve_forever() from a separate thread
        # (calling server.shutdown() from the handler's own thread would deadlock).
        self._json(200, {"status": "shutting down"})
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

if __name__ == "__main__":
    if not HTML_FILE.exists():
        print("ERROR: index.html not found next to ai_server.py", file=sys.stderr); sys.exit(1)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", WEB_PORT), Handler)
    print("AI Assistant running at http://localhost:" + str(WEB_PORT))
    print("Press Ctrl+C to stop.")
    try:    server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()
PY_EOF

chmod +x "$WEB_DIR/ai_server.py"

# ==============================================================================
# STEP 7: Write the launcher script
# ==============================================================================
echo "🚀 Writing launcher..."

LAUNCHER_SCRIPT="$DEST_DIR/launch_ai.sh"

cat > "$LAUNCHER_SCRIPT" << 'LAUNCHER_EOF'
#!/bin/bash

export PATH="$HOME/.local/bin:$PATH"

DEST_DIR="$HOME/AI_Models"
WEB_DIR="$DEST_DIR/web_ui"

if [ ! -d "$DEST_DIR" ]; then
    zenity --error --title="Directory Error" --text="The AI_Models directory was not found on your system." \
        --ok-label="Close" --width=400 2>/dev/null
    exit 1
fi

LLAMA_BIN=""
for candidate in \
    "$HOME/.local/bin/llama-server" \
    "$([ -f /home/linuxbrew/.linuxbrew/bin/brew ] && /home/linuxbrew/.linuxbrew/bin/brew --prefix 2>/dev/null)/bin/llama-server" \
    "$HOME/.linuxbrew/bin/llama-server" \
    "/usr/local/bin/llama-server" \
    "/usr/bin/llama-server"; do
    if [ -f "$candidate" ]; then
        LLAMA_BIN="$candidate"
        break
    fi
done

if [ -z "$LLAMA_BIN" ]; then
    zenity --error --title="Server Engine Not Found" \
        --text="The llama-server engine is not installed.\n\nPlease run the main setup script again to install it." \
        --ok-label="Close" --width=400 2>/dev/null
    exit 1
fi

cd "$DEST_DIR" || exit 1

while true; do
    shopt -s nullglob; MODELS=(*.gguf); shopt -u nullglob

    ACTION=$(zenity --list --title="Local LLM Manager Menu" \
        --text="Choose an action from the list below." \
        --column="Available Action" \
        --ok-label="Select Action" --cancel-label="Quit Manager" \
        "Launch AI Assistant" "Download a Model" "Delete a Model" "Quit" \
        --width=420 --height=280 2>/dev/null)

    [ -z "$ACTION" ] || [ "$ACTION" = "Quit" ] && exit 0

    if [ "$ACTION" = "Download a Model" ]; then
        DL_SELECTED=$(zenity --list --title="Download New AI Model" \
            --text="Choose a model to download." \
            --column="Model Name" --column="Estimated Size" \
            --print-column=1 --width=600 --height=200 \
            --ok-label="Download Selected Model" --cancel-label="Go Back" \
            "Llama 3.2 (3B - Super Fast)"  "~ 2.0 GB" \
            "✨ Paste Custom GGUF URL"     "Custom Size" \
            2>/dev/null)
        [ -z "$DL_SELECTED" ] && continue

        DL_URL=""
        DL_FILE=""

        if [ "$DL_SELECTED" = "Llama 3.2 (3B - Super Fast)" ]; then
            DL_FILE="Llama-3.2-3B-Instruct-Q4_K_M.gguf"
            DL_URL="https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        elif [ "$DL_SELECTED" = "✨ Paste Custom GGUF URL" ]; then
            CUSTOM_INPUT=$(zenity --entry --title="Custom Download Link" \
                --text="How to get a link:\n1) Search Hugging Face GGUF models\n2) Choose any model\n3) Select 'Files and versions'\n4) Copy the url or download link of the .gguf file\n\nPaste the direct download URL below and press Enter:" \
                --ok-label="Download" --cancel-label="Cancel" --width=600 2>/dev/null)
            [ -z "$CUSTOM_INPUT" ] && continue
            CUSTOM_INPUT=$(echo "$CUSTOM_INPUT" | tr -d '\r\n ')
            
            if [[ "$CUSTOM_INPUT" == *"huggingface.co"* && "$CUSTOM_INPUT" == *"/blob/"* ]]; then
                CUSTOM_INPUT="${CUSTOM_INPUT/\/blob\//\/resolve\/}"
            fi
            EXTRACTED_NAME=$(basename "$CUSTOM_INPUT" | cut -d'?' -f1)
            if [[ ! "$CUSTOM_INPUT" =~ ^https?:// ]] || [[ "$EXTRACTED_NAME" != *.gguf ]]; then
                zenity --error --title="Invalid Model Link" \
                    --text="The URL you entered is not a valid GGUF model link.\n\nPlease paste a direct download URL ending in .gguf\n(e.g. https://huggingface.co/.../model.gguf)" \
                    --ok-label="Close" --width=480 2>/dev/null || true
                continue
            fi
            DL_FILE="${EXTRACTED_NAME%.gguf}.gguf"
            DL_URL="$CUSTOM_INPUT"
        fi

        DL_PATH="$DEST_DIR/$DL_FILE"
        if [ -f "$DL_PATH" ]; then
            zenity --info --title="File Already Exists" \
                --text="$DL_FILE has already been downloaded to your system." \
                --ok-label="Go Back" --width=400 2>/dev/null
            continue
        fi

        if ! curl -sf --max-time 5 https://huggingface.co > /dev/null 2>&1; then
            zenity --error --title="No Internet Connection" \
                --text="Cannot reach the download server. Please check your network connection." \
                --ok-label="Close" --width=400 2>/dev/null
            continue
        fi

        clear
        echo "======================================================="
        echo "   DOWNLOADING MODEL"
        echo "   File: $DL_FILE"
        echo "   URL:  $DL_URL"
        echo "======================================================="
        
        wget --show-progress -O "$DL_PATH" "$DL_URL"
        DL_EXIT=$?

        if [ $DL_EXIT -ne 0 ] || [ ! -f "$DL_PATH" ]; then
            rm -f "$DL_PATH"
            zenity --warning --title="Download Incomplete" \
                --text="The model download failed or was cancelled before completion." \
                --ok-label="Close" --width=380 2>/dev/null || true
        else
            zenity --info --title="Download Complete" \
                --text="The model was successfully downloaded. You can now launch it from the main menu." \
                --ok-label="Return to Menu" --width=420 2>/dev/null
        fi
        continue
    fi

    if [ ${#MODELS[@]} -eq 0 ]; then
        zenity --warning --title="No Models Found" \
            --text="There are no AI models currently installed on your system.\n\nPlease select 'Download a Model' from the menu first." \
            --ok-label="Close" --width=400 2>/dev/null
        continue
    fi

    if [ "$ACTION" = "Delete a Model" ]; then
        DEL=$(zenity --list --title="Delete Installed Model" \
            --text="Select the model you wish to permanently delete, then press Enter." \
            --column="Currently Installed Models" "${MODELS[@]}" \
            --ok-label="Delete Selected" --cancel-label="Cancel" --width=500 --height=300 2>/dev/null)
        if [ -n "$DEL" ]; then
            zenity --question --title="Confirm Deletion" \
                --text="Are you sure you want to permanently delete $DEL from your system?" \
                --ok-label="Yes, Delete It" --cancel-label="No, Keep It" --width=400 2>/dev/null \
            && rm -f "$DEL" \
            && zenity --info --title="Model Deleted" --text="$DEL has been removed from your system." \
               --ok-label="Close" --width=300 2>/dev/null
        fi
        continue
    fi

    if [ "$ACTION" = "Launch AI Assistant" ]; then
        SELECTED=$(zenity --list --title="Choose AI Model to Launch" \
            --text="Select the model you wish to run, then press Enter." \
            --column="Currently Installed Models" "${MODELS[@]}" \
            --ok-label="Launch Model" --cancel-label="Cancel" --width=500 --height=300 2>/dev/null)
        [ -z "$SELECTED" ] && continue

        clear
        echo "======================================================="
        echo "   STARTING YOUR LOCAL LLM"
        echo "   Model: $SELECTED"
        echo "======================================================="
        echo "  Leave this terminal window open while using the AI."
        echo "  Click 'Close' in the AI Assistant window, or press Ctrl+C here, when finished."
        echo "======================================================="

        pkill -f "ai_server.py"   2>/dev/null || true
        pkill -f "llama-server"   2>/dev/null || true
        sleep 1

        "$LLAMA_BIN" \
            -m "$DEST_DIR/$SELECTED" \
            --host 127.0.0.1 \
            --port 8080 \
            -c 4096 \
            -np 1 \
            > /tmp/llama-server.log 2>&1 &
        LLAMA_PID=$!

        echo "  Waiting for model to load into memory (this may take 10 to 60 seconds)..."
        LOADED=0
        for i in $(seq 1 60); do
            if curl -sf --max-time 2 http://127.0.0.1:8080/v1/models > /dev/null 2>&1; then
                echo "  Model loaded successfully!"; LOADED=1; break
            fi
            if ! kill -0 "$LLAMA_PID" 2>/dev/null; then
                echo "  System Error: Model failed to start. Check /tmp/llama-server.log"
                zenity --error --title="Startup Failure" \
                    --text="The AI model failed to start.\n\nPlease review /tmp/llama-server.log for details." \
                    --ok-label="Close" --width=400 2>/dev/null || true
                break
            fi
            sleep 2
            echo "  Still loading... ($((i*2)) seconds elapsed)"
        done

        if [ "$LOADED" -eq 0 ]; then continue; fi

        python3 "$WEB_DIR/ai_server.py" > /tmp/ai_server.log 2>&1 &
        SERVER_PID=$!
        sleep 2

        # ----------------------------------------------------------------------
        # ACCESSIBILITY FOCUS HANDOFF
        # Use nohup to detach the process completely, bypassing GNOME focus limits
        # Use wmctrl to explicitly command the window manager to grab the window
        # ----------------------------------------------------------------------
        echo ""
        echo "  Your Local LLM is ready at: http://localhost:8000"
        echo "  Click 'Close' in the AI Assistant window, or press Ctrl+C here, when finished."
        echo "  Opening browser now. Please wait for focus to shift..."

        # Wait for the Python web server to actually be ready before opening browser
        echo "  Waiting for web server to be ready..."
        for i in $(seq 1 15); do
            if curl -sf --max-time 1 http://127.0.0.1:8000/ > /dev/null 2>&1; then
                echo "  Web server ready!"; break
            fi
            sleep 0.5
        done

        if command -v xdg-open &>/dev/null; then
            nohup xdg-open http://localhost:8000 >/dev/null 2>&1 &
        else
            nohup firefox http://localhost:8000 >/dev/null 2>&1 &
        fi

        # Run focus grabber in the background
        (
            sleep 3
            if command -v wmctrl &>/dev/null; then
                wmctrl -a "Local LLM - Zendalona" 2>/dev/null || wmctrl -a "Firefox" 2>/dev/null
            fi
        ) &

        trap "kill $LLAMA_PID $SERVER_PID 2>/dev/null" INT TERM

        # Wait until either process exits. Normally that's ai_server.py, which
        # exits as soon as the in-page Close button is clicked (it pings
        # /api/shutdown right before window.close()). Once either one is gone,
        # kill the other so we don't leave llama-server running in the background.
        while kill -0 "$LLAMA_PID" 2>/dev/null && kill -0 "$SERVER_PID" 2>/dev/null; do
            sleep 1
        done
        kill "$LLAMA_PID" "$SERVER_PID" 2>/dev/null || true
        trap - INT TERM
        echo ""
        echo "  AI Assistant closed. Model and server shut down. Returning to main menu."
        echo ""; sleep 2
    fi
done
LAUNCHER_EOF

chmod +x "$LAUNCHER_SCRIPT"

# ==============================================================================
# STEP 8: Application menu entry (no Desktop icon)
# ==============================================================================
CREATED_SHORTCUTS=1

# Download Zendalona logo for the launcher icon
ICON_PATH="$DEST_DIR/zendalona-logo.png"
if [ ! -f "$ICON_PATH" ]; then
    wget -q -O "$ICON_PATH" \
        "https://i0.wp.com/zendalona.com/wp-content/uploads/2025/11/zenda-backgr-logo.png?w=512&ssl=1" \
        2>/dev/null || true
fi
# Fall back to orca icon if download failed
if [ ! -f "$ICON_PATH" ] || [ ! -s "$ICON_PATH" ]; then
    ICON_PATH="/usr/share/icons/hicolor/scalable/apps/orca.svg"
fi

mkdir -p "$HOME/.local/share/applications"
APP_ENTRY="$HOME/.local/share/applications/Launch_AI.desktop"

cat > "$APP_ENTRY" << EOF
[Desktop Entry]
Name=Local LLM
Comment=Local AI Assistant for visually impaired users
Exec=$LAUNCHER_SCRIPT
Terminal=true
Type=Application
Categories=Zendalona;other;
Icon=$ICON_PATH
EOF

chmod +x "$APP_ENTRY"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

# ==============================================================================
# DONE
# ==============================================================================
INSTALLATION_SUCCESS=1
zenity --info --title="Initial Setup Complete" \
    --text="Installation successfully finished!\n\nTo start your Local LLM:\n  Open your application menu and look under Zendalona or Other." \
    --ok-label="Finish and Close" --width=480 2>/dev/null
