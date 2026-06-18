#!/bin/bash

LOGFILE="$HOME/local_llm_gemma_install.log"
exec > >(tee -i "$LOGFILE")
exec 2>&1

speak() {
    echo "$1"
}

sudo apt-get install -y curl zenity

# ── Internet check helper ─────────────────────────────────────────────────────
check_internet() {
    local CONTEXT="${1:-}"
    if ! curl -sf --max-time 5 https://ollama.com > /dev/null 2>&1; then
        local MSG="Internet disconnected ${CONTEXT}. Please check your connection and try again."
        speak "Internet disconnected. $CONTEXT. Please check your connection."
        zenity --error \
            --title="No Internet Connection" \
            --text="$MSG" \
            --width=400 \
            2>/dev/null || true
        echo "FATAL: $MSG"
        return 1
    fi
}

speak "Starting setup"

export DEBIAN_FRONTEND=noninteractive

# ── STEP 0: Check free space in GB for root partition ──────────────────
FREE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')


zenity --question \
       --title="Sufficient resource? " \
       --text="⚠️ Disk Space Available: ${FREE_SPACE}GB\nRequired: 15GB + Model size! Larger models require proportionate RAM. Do you want to continue?" \
       --width=400 \
       --ok-label="Continue" \
       --cancel-label="Cancel"
    
if [ $? -eq 1 ]; then
   # User clicked Cancel
   exit 0
fi


# ── STEP 1: Install system packages if not already installed ──────────────────
if ! command -v docker &> /dev/null; then
    speak "Installing docker packages"
    sudo apt-get install -y docker.io 
    speak "System packages installed"
fi


# ── STEP 2: Install Ollama if not already installed ───────────────────────────
if ! command -v ollama &> /dev/null; then
    speak "Installing Ollama"
    check_internet "before installing Ollama"
    curl -fsSL https://ollama.com/install.sh | sh
    speak "Ollama installed"
else
    speak "Ollama already installed, skipping"
fi

# ── STEP 3: Clean previous run ────────────────────────────────────────────────
speak "Cleaning previous run"
sudo docker rm -f open-webui 2>/dev/null || true
sudo systemctl stop ollama 2>/dev/null || true
sleep 2

# ── STEP 4: Start Docker ──────────────────────────────────────────────────────
speak "Starting Docker"
sudo systemctl enable docker
sudo systemctl start docker
sleep 3

# ── STEP 5: Start Ollama ──────────────────────────────────────────────────────
speak "Starting Ollama"
sudo systemctl enable ollama
sudo systemctl start ollama
sleep 5

# ── STEP 6: Wait for Ollama to be ready ──────────────────────────────────────
speak "Waiting for Ollama to be ready"
READY=0
for i in {1..30}; do
    if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        speak "Ollama is ready"
        READY=1
        break
    fi
    echo "Attempt $i: Ollama not ready yet, waiting..."
    sleep 8
done

if [ "$READY" -eq 0 ]; then
    speak "Ollama failed to start. Check log file. Press any key to Quit"
    read -n 1
    exit 0
fi

# ── STEP 7: Detect desktop user ───────────────────────────────────────────────
DESKTOP_USER=$(whoami)
USER_ID=$(id -u)

# ── STEP 8: Fetch available Gemma models by scraping ollama.com/library ───────
speak "Fetching available Gemma models online"
check_internet "while fetching model list"

declare -a MODEL_TAGS=()
declare -a MODEL_SIZES=()

fetch_tags_for_family() {
    local FAMILY="$1"
    local PAGE
    PAGE=$(curl -sf --max-time 15 "https://ollama.com/library/${FAMILY}/tags" 2>/dev/null) || return

    local LAST_TAG=""
    while IFS= read -r LINE; do
        if echo "$LINE" | grep -qP "/library/${FAMILY}:[a-z0-9]"; then
            CANDIDATE=$(echo "$LINE" | grep -oP "(?<=/library/${FAMILY}:)[a-z0-9][a-z0-9._-]+")
            if echo "$CANDIDATE" | grep -qE '(q4|q8|bf16|mlx|mxfp|nvfp|fp16|-it-)'; then
                LAST_TAG=""
                continue
            fi
            if [ "$CANDIDATE" = "latest" ]; then
                LAST_TAG=""
                continue
            fi
            LAST_TAG="${FAMILY}:${CANDIDATE}"
        fi

        if [ -n "$LAST_TAG" ] && echo "$LINE" | grep -qP '•\s*[0-9]+(\.[0-9]+)?GB\s*•'; then
            SIZE=$(echo "$LINE" | grep -oP '[0-9]+(\.[0-9]+)?GB' | head -1)
            if ! printf '%s\n' "${MODEL_TAGS[@]}" | grep -qx "$LAST_TAG"; then
                MODEL_TAGS+=("$LAST_TAG")
                MODEL_SIZES+=("$SIZE")
            fi
            LAST_TAG=""
        fi
    done <<< "$PAGE"
}

fetch_tags_for_family "gemma4"

if [ "${#MODEL_TAGS[@]}" -eq 0 ]; then
    fetch_tags_for_family "gemma3"
fi

if [ "${#MODEL_TAGS[@]}" -eq 0 ]; then
    speak "Could not parse model list, using built-in defaults"
    MODEL_TAGS=("gemma4:e4b" "gemma4:e2b" "gemma4:26b" "gemma4:31b")
    MODEL_SIZES=("9.6GB"     "7.2GB"      "18GB"       "20GB")
fi

speak "Found ${#MODEL_TAGS[@]} models"
echo "Models found: ${MODEL_TAGS[*]}"
echo "Sizes found:  ${MODEL_SIZES[*]}"

# ── STEP 9: Check which models are already installed & build Zenity args ──────
installed() {
    curl -s http://127.0.0.1:11434/api/tags | grep -q "\"$1\"" && echo "Downloaded" || echo "Not Downloaded"
}

ZENITY_ARGS=(
    --list
    --title="Gemma Model Selector"
    "--text=Select a Gemma model to install or remove:"
    --column="Model Tag"
    --column="Status"
    --column="Size"
    --separator="|"
    --width=700
    --height=350
)

FIRST=TRUE
for i in "${!MODEL_TAGS[@]}"; do
    TAG="${MODEL_TAGS[$i]}"
    SIZE="${MODEL_SIZES[$i]}"
    STATUS=$(installed "$TAG")
    ZENITY_ARGS+=("$TAG" "$STATUS" "$SIZE")
    FIRST=FALSE
done

SELECTED=$(zenity "${ZENITY_ARGS[@]}" 2>/dev/null)

ZENITY_EXIT=$?

if [ $ZENITY_EXIT -ne 0 ]; then
    speak "No model selected. Exiting."
    zenity --error --title="Cancelled" --text="No model selected. Setup cancelled." 2>/dev/null
    exit 0
fi

if [ -z "$SELECTED" ]; then
    speak "No selection detected"
    exit 0
fi

MODEL_TAG=$(echo "$SELECTED" | cut -d'|' -f1)
speak "Model selected: $MODEL_TAG"

# ── STEP 10: Download only if not already present ────────────────────────────
ALREADY=$(curl -s http://127.0.0.1:11434/api/tags | grep -c "\"$MODEL_TAG\"" || true)

if [ "$ALREADY" -gt 0 ]; then
    speak "Model already present, skipping download"
    if zenity --question \
        --title="Model already present!" \
        --text="Do you want to remove the model $MODEL_TAG?" \
        --width=400 \
        --ok-label="Yes" \
        --cancel-label="No"; then
        # User clicked Yes → remove the model
        echo "Removing $MODEL_TAG..."
        ollama rm "$MODEL_TAG"
        echo "$MODEL_TAG removed!"
        exit 0
    else
        # User clicked No or closed the dialog
        echo "Keeping $MODEL_TAG."
    fi

    sleep 2
else
    check_internet "before downloading $MODEL_TAG"

    speak "Downloading $MODEL_TAG please wait"
    zenity --info --title="Downloading" \
        --text="Downloading $MODEL_TAG...\nThis may take several minutes. Please note that you will be prompted to enter your password at the end." 2>/dev/null &
    ZPID=$!

    ollama pull "$MODEL_TAG" &
    PULL_PID=$!
    wait $PULL_PID
    PULL_EXIT=$?

    kill $ZPID 2>/dev/null || true

    if [ $PULL_EXIT -ne 0 ]; then
        if ! curl -sf --max-time 5 https://ollama.com > /dev/null 2>&1; then
            MSG="Internet disconnected while downloading $MODEL_TAG. Please reconnect and try again."
            speak "Internet disconnected during download. Please reconnect and try again."
            zenity --error --title="Download Failed - No Internet" \
                --text="$MSG" --width=400 2>/dev/null || true
        else
            MSG="Download of $MODEL_TAG failed. Check log for details."
            speak "Download failed. Check log file."
            zenity --error --title="Download Failed" \
                --text="$MSG" --width=400 2>/dev/null || true
        fi
        echo "Press any key to Quit"
        read -n 1
        exit 0
    fi

    speak "Download complete"
fi

# ── STEP 11: Confirm model is visible in Ollama ───────────────────────────────
speak "Confirming model in Ollama"
FOUND=0
for i in {1..20}; do
    if curl -s http://127.0.0.1:11434/api/tags | grep -q "${MODEL_TAG%%:*}"; then
        speak "Model confirmed"
        FOUND=1
        break
    fi
    sleep 5
done

if [ "$FOUND" -eq 0 ]; then
    speak "Model not found. Check log file. Press any key to Quit"
    read -n 1
    exit 0
fi

speak "Setting up the executable and launcher"
#Step 12 Setup the executable and launcher
sudo tee /usr/local/bin/run_local_llm_gemma > /dev/null << 'EOF'
#!/bin/bash

speak() {
    echo "$1"
}

# ── STEP 4: Start Docker ──────────────────────────────────────────────────────
speak "Starting Docker"
sudo systemctl enable docker
sudo systemctl start docker
sleep 3

# ── STEP 5: Start Ollama ──────────────────────────────────────────────────────
speak "Starting Ollama"
sudo systemctl enable ollama
sudo systemctl start ollama
sleep 5

# ── STEP 6: Wait for Ollama to be ready ──────────────────────────────────────
speak "Waiting for Ollama to be ready"
READY=0
for i in {1..30}; do
    if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        speak "Ollama is ready"
        READY=1
        break
    fi
    echo "Attempt $i: Ollama not ready yet, waiting..."
    sleep 8
done

if [ "$READY" -eq 0 ]; then
    speak "Ollama failed to start. Check log file."
    exit 1
fi

sudo docker rm open-webui

# ── STEP 13: Start Open WebUI ─────────────────────────────────────────────────
speak "Starting Open WebUI"
sudo docker run -d \
    --network=host \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    -e WEBUI_AUTH=False \
    -e ENABLE_RAG_WEB_SEARCH=false \
    -e ENABLE_RAG_EMBEDDING=false \
    -e ENABLE_IMAGE_GENERATION=false \
    -e ENABLE_OLLAMA_API=true \
    -e OFFLINE_MODE=true \
    -e CUDA_VISIBLE_DEVICES="" \
    -v open-webui:/app/backend/data \
    --name open-webui \
    ghcr.io/open-webui/open-webui:main

# ── STEP 14: Wait for Open WebUI to be ready ─────────────────────────────────
speak "Waiting for Open WebUI to be ready"
for i in {1..40}; do
    if curl -s http://localhost:8080 > /dev/null 2>&1; then
        speak "Web interface is ready"
        firefox http://localhost:8080 </dev/null >/dev/null 2>&1
        break
    fi
    echo "Attempt $i: WebUI not ready yet, waiting..."
    sleep 5
done
EOF

sudo chmod +x /usr/local/bin/run_local_llm_gemma

sudo mkdir -p /usr/local/share/applications/zendalona/

sudo tee /usr/local/share/applications/zendalona/run_local_llm_gemma.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=Run Local LLM Gemma
Comment=Version and Changelog
Icon=/usr/share/Coconut/tree.svg
Exec=run_local_llm_gemma
Terminal=true
Type=Application
Categories=Zendalona;
EOF

sudo update-desktop-database

# ── STEP 13: Start Open WebUI ─────────────────────────────────────────────────
speak "Starting Open WebUI"
sudo docker rm -f open-webui 2>/dev/null || true

sudo docker run -d \
    --network=host \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    -e WEBUI_AUTH=False \
    -e ENABLE_RAG_WEB_SEARCH=false \
    -e ENABLE_RAG_EMBEDDING=false \
    -e ENABLE_IMAGE_GENERATION=false \
    -e ENABLE_OLLAMA_API=true \
    -e OFFLINE_MODE=true \
    -e CUDA_VISIBLE_DEVICES="" \
    -v open-webui:/app/backend/data \
    --name open-webui \
    ghcr.io/open-webui/open-webui:main

# ── STEP 14: Wait for Open WebUI to be ready ─────────────────────────────────
speak "Waiting for Open WebUI to be ready"
for i in {1..40}; do
    if curl -s http://localhost:8080 > /dev/null 2>&1; then
        speak "Web interface is ready"
        zenity --info --title="Local LLM Gemma" --text="The 'Run Local LLM Gemma' will be available in\nZendalona menu or Other Menu.\
        \n\nYou can skip the welcome message in WebUI by pressing ESCAPE button"
        firefox http://localhost:8080 </dev/null >/dev/null 2>&1
        break
    fi
    echo "Attempt $i: WebUI not ready yet, waiting..."
    sleep 5
done

echo "Press any key to Quit"
read -n 1
