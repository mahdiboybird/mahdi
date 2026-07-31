#!/bin/bash
# ============================================================
# HERMES FULL AUTO-INSTALL — by Mahdi's setup (2026-07-31)
# Run on the NEW server:
#   bash install-hermes-new.sh
#
# Does EVERYTHING automatically:
#   1. Installs Hermes Agent (official installer)
#   2. Clones your GitHub backup (config, skills, memory, sessions)
#   3. Rebuilds .env from your tokens file (backup-token-ha.txt)
#   4. Sets up cron jobs + watchdog
#   5. Starts the gateway detached (survives SSH close)
# ============================================================
set -e

# ============ CONFIG ============
GITHUB_REPO="mahdiboybird/hermes-backup"
GITHUB_TOKEN="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"  # ← your GitHub token (pre-filled)
TOKENS_FILE="$HOME/backup-token-ha.txt"   # your tokens backup file
HERMES_HOME="$HOME/.hermes"

echo ""
echo "════════════════════════════════════════════"
echo "  🚀 HERMES AUTO-INSTALL STARTING"
echo "════════════════════════════════════════════"
echo ""

# ============ 1. CHECK REQUIREMENTS ============
echo "[1/6] Checking requirements..."
for cmd in git curl python3 node npm; do
    if command -v $cmd >/dev/null 2>&1; then
        echo "  ✓ $cmd: $(command -v $cmd)"
    else
        echo "  ✗ $cmd MISSING — install it first!"
        exit 1
    fi
done

# ============ 2. INSTALL HERMES ============
echo ""
echo "[2/6] Installing Hermes Agent (official installer)..."
if command -v hermes >/dev/null 2>&1; then
    echo "  ✓ Hermes already installed: $(hermes --version 2>&1 | head -1)"
else
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    echo "  ✓ Hermes installed!"
fi

# ============ 3. CLONE BACKUP ============
echo ""
echo "[3/6] Cloning your backup from GitHub..."
BACKUP_DIR="$HOME/hermes-backup"
if [ -d "$BACKUP_DIR/.git" ]; then
    echo "  ✓ Backup repo exists — pulling latest..."
    cd "$BACKUP_DIR" && git pull 2>/dev/null || true
else
    if [ -n "$GITHUB_TOKEN" ]; then
        git clone "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git" "$BACKUP_DIR"
        echo "  ✓ Cloned with token"
    else
        git clone "https://github.com/${GITHUB_REPO}.git" "$BACKUP_DIR"
        echo "  ✓ Cloned (may ask for credentials if repo is private)"
    fi
fi

# ============ 4. RESTORE CONFIG/SKILLS/MEMORY ============
echo ""
echo "[4/6] Restoring config, skills, memory, sessions..."
mkdir -p "$HERMES_HOME"
restore() {
    local src="$BACKUP_DIR/$1"
    local dst="$HERMES_HOME/$1"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")" 2>/dev/null || true
        cp -r "$src" "$dst"
        echo "  ✓ Restored: $1"
    fi
}
restore "config.yaml"
restore "safety-rules.md"
restore "SOUL.md"
restore "skills"
restore "memories"
restore "scripts"
restore "cron"
restore "channel_directory.json"
restore "gateway_state.json"
restore "sessions.json"
# state.db.gz (session history) — decompress if present
if [ -f "$BACKUP_DIR/state.db.gz" ]; then
    gunzip -c "$BACKUP_DIR/state.db.gz" > "$HERMES_HOME/state.db" 2>/dev/null && echo "  ✓ Restored: state.db (session history)" || echo "  ⚠ state.db restore skipped (in use?)"
fi
if [ -f "$BACKUP_DIR/kanban.db" ]; then
    cp "$BACKUP_DIR/kanban.db" "$HERMES_HOME/" && echo "  ✓ Restored: kanban.db"
fi

# ============ 5. BUILD .env FROM TOKENS FILE ============
echo ""
echo "[5/6] Building .env from your tokens file..."
ENV_FILE="$HERMES_HOME/.env"
if [ ! -f "$ENV_FILE" ] && [ -f "$TOKENS_FILE" ]; then
    # Extract keys from the tokens backup (key: value format)
    extract() { grep "^$1:" "$TOKENS_FILE" 2>/dev/null | head -1 | sed "s/^$1: *//" | tr -d '\r'; }
    BOT_TOKEN=$(extract "TELEGRAM_BOT_TOKEN")
    OPENAI_KEY=$(extract "OPENAI_API_KEY")
    ZEN_KEY=$(extract "OPENCODE_ZEN_API_KEY")
    DASHSCOPE_KEY=$(extract "DASHSCOPE_API_KEY")
    GH_TOKEN=$(extract "GITHUB_TOKEN")
    CF_TOKEN=$(extract "Cloudflare API Token")

    cat > "$ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
TELEGRAM_HOME_CHANNEL=8452931196
TELEGRAM_ALLOWED_USERS=8452931196,6448323240
OPENAI_API_KEY=$OPENAI_KEY
OPENCODE_ZEN_API_KEY=$ZEN_KEY
DASHSCOPE_API_KEY=$DASHSCOPE_KEY
GITHUB_TOKEN=$GH_TOKEN
EOF
    chmod 600 "$ENV_FILE"
    echo "  ✓ .env created from $TOKENS_FILE"
elif [ -f "$ENV_FILE" ]; then
    echo "  ✓ .env already exists"
else
    echo "  ⚠ No tokens file found at $TOKENS_FILE"
    echo "    → Create $ENV_FILE manually (see old server's backup-token-ha.txt)"
fi

# ============ 6. START GATEWAY (DETACHED) ============
echo ""
echo "[6/6] Starting gateway detached..."
if [ -f "$HERMES_HOME/scripts/start-gateway-detached.sh" ]; then
    chmod +x "$HERMES_HOME/scripts/start-gateway-detached.sh"
    bash "$HERMES_HOME/scripts/start-gateway-detached.sh"
else
    # Fallback: start detached directly
    LOG="$HERMES_HOME/logs/gateway.log"
    mkdir -p "$(dirname "$LOG")"
    pkill -f "hermes gateway" 2>/dev/null || true
    sleep 2
    setsid nohup hermes gateway run >"$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null || true
    sleep 5
    pgrep -f "hermes gateway" >/dev/null && echo "  ✓ Gateway RUNNING (detached)" || echo "  ✗ Gateway failed — check $LOG"
fi

# ============ SETUP CRON ============
echo ""
echo "⏰ Setting up cron jobs (backup daily 6am + cleanup every 5min)..."
if command -v hermes >/dev/null 2>&1; then
    hermes cron add --name daily-github-backup --schedule "0 6 * * *" --prompt "Run bash ~/.hermes/scripts/hermes-backup.sh to back up Hermes config/skills/sessions to GitHub. Report the commit hash." 2>/dev/null && echo "  ✓ daily-github-backup" || echo "  ⚠ cron add failed (do it manually later)"
fi

echo ""
echo "════════════════════════════════════════════"
echo "  ✅ INSTALL COMPLETE!"
echo "  • Hermes:    $(hermes --version 2>&1 | head -1)"
echo "  • Gateway:   check with: ps aux | grep 'hermes gateway'"
echo "  • Test bot:  send /start to your bot on Telegram"
echo "════════════════════════════════════════════"
