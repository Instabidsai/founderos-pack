#!/usr/bin/env bash
#
# FounderOS — bootstrap installer (v0.1.1)
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Instabidsai/founderos-pack/main/install.sh | bash -s -- <TOKEN>
#   OR
#   bash install.sh <TOKEN>
#
# Resumable: re-running with the same token picks up from the last completed phase.
# State: ~/.founderos/install.state
#
set -euo pipefail

TOKEN="${1:-}"
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: install token required"
  echo "Usage: bash install.sh <TOKEN>"
  exit 1
fi

VERSION="0.1.3"
PACK_URL="${FOS_PACK_URL:-https://github.com/Instabidsai/founderos-pack/releases/download/v${VERSION}/founderos-skill-pack-v${VERSION}.tar.gz}"
ADMIN_URL="${FOS_ADMIN_URL:-https://wdvfwtecvdhtvmyeymgy.supabase.co}"
ADMIN_KEY="${FOS_ADMIN_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndkdmZ3dGVjdmRodHZteWV5bWd5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzExNTU3MjEsImV4cCI6MjA4NjczMTcyMX0.01rJXoNV8VCzEQe1guCd0Z9Ff3kkCHgacGMyO9QWcDM}"

STATE_DIR="$HOME/.founderos"
STATE_FILE="$STATE_DIR/install.state"
LOG_FILE="$STATE_DIR/install.log"
mkdir -p "$STATE_DIR"

PYTHON=$(command -v python3 2>/dev/null || command -v python)
[[ -n "$PYTHON" ]] || { echo "python missing"; exit 1; }

say()   { printf "\n\033[1;36m==> %s\033[0m\n" "$*" | tee -a "$LOG_FILE"; }
ok()    { printf "   \033[1;32m[OK]\033[0m %s\n" "$*" | tee -a "$LOG_FILE"; }
warn()  { printf "   \033[1;33m[WARN]\033[0m %s\n" "$*" | tee -a "$LOG_FILE"; }
die()   { printf "\n\033[1;31mFAIL: %s\033[0m\n" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

phase_done()  { echo "$1" >> "$STATE_FILE"; }
phase_skip()  { [[ -f "$STATE_FILE" ]] && grep -qx "$1" "$STATE_FILE" 2>/dev/null; }

# ------------------------------------------------------------------
# Phase 1  —  environment check + fetch pack (so _lib.py is available)
# ------------------------------------------------------------------
if ! phase_skip 1; then
  say "Phase 1 / 7  —  environment check + fetch pack"
  command -v curl >/dev/null || die "curl missing"
  command -v tar >/dev/null || die "tar missing"
  command -v claude >/dev/null || die "Claude Code not installed. Install from https://claude.com/claude-code first."
  mkdir -p "$HOME/.claude/skills"

  rm -rf "$STATE_DIR/pack"
  mkdir -p "$STATE_DIR/pack"
  curl -sfL "$PACK_URL" -o "$STATE_DIR/pack.tar.gz" || die "failed to fetch $PACK_URL"
  tar xzf "$STATE_DIR/pack.tar.gz" -C "$STATE_DIR/pack" --strip-components=1
  [[ -f "$STATE_DIR/pack/install/_lib.py" ]] || die "_lib.py missing from pack"
  ok "curl + python + claude ready; pack v$VERSION extracted"
  phase_done 1
else
  ok "Phase 1 already complete"
fi

LIB="$STATE_DIR/pack/install/_lib.py"

# ------------------------------------------------------------------
# Phase 2  —  validate token (idempotent now) + fetch tenant config
# ------------------------------------------------------------------
if ! phase_skip 2; then
  say "Phase 2 / 7  —  validating install token"
  VALIDATE=$(curl -s -X POST "$ADMIN_URL/rest/v1/rpc/validate_install_token" \
    -H "apikey: $ADMIN_KEY" -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"p_token\":\"$TOKEN\"}") || die "token validation request failed"

  printf '%s' "$VALIDATE" | "$PYTHON" "$LIB" parse-token > "$STATE_DIR/env.sh" \
    || die "token rejected — check the token or ask for a new one"
  chmod 600 "$STATE_DIR/env.sh"
fi
# Always source env (even on skip) so later phases have FOS_* vars
source "$STATE_DIR/env.sh"
[[ -n "${FOS_SUPABASE_URL:-}" ]] || die "token did not include supabase_url"
phase_skip 2 || { ok "Token valid — installing for $FOS_OWNER_NAME @ $FOS_BUSINESS_NAME"; phase_done 2; }

# ------------------------------------------------------------------
# Phase 3  —  Supabase reachability check
# (schema apply is admin-side; installer only VERIFIES tables are live)
# ------------------------------------------------------------------
if ! phase_skip 3; then
  say "Phase 3 / 7  —  verifying tenant Supabase"
  curl -sf "$FOS_SUPABASE_URL/rest/v1/" -H "apikey: $FOS_SUPABASE_ANON_KEY" >/dev/null \
    || die "tenant Supabase unreachable at $FOS_SUPABASE_URL"

  MISSING=0
  for T in owner_memory owner_mental_model owner_threads owner_rejections owner_sessions owner_snapshots owner_todos owner_skill_requests; do
    curl -sf "$FOS_SUPABASE_URL/rest/v1/$T?limit=0" \
      -H "apikey: $FOS_SUPABASE_ANON_KEY" >/dev/null 2>&1 \
      || { warn "table $T not reachable"; MISSING=$((MISSING+1)); }
  done
  if (( MISSING > 0 )); then
    die "$MISSING tenant table(s) missing. Admin must run provision-tenant.sh first (or retry install after admin applies schema)."
  fi
  ok "all tenant tables reachable"
  phase_done 3
else
  ok "Phase 3 already complete"
fi

# ------------------------------------------------------------------
# Phase 4  —  install skills + substitute placeholders
# ------------------------------------------------------------------
if ! phase_skip 4; then
  say "Phase 4 / 7  —  installing skills"
  for S in owner ops builder init-founderos; do
    SRC="$STATE_DIR/pack/skills/$S"
    [[ -d "$SRC" ]] || { warn "pack missing skills/$S"; continue; }
    rm -rf "$HOME/.claude/skills/$S"
    cp -r "$SRC" "$HOME/.claude/skills/$S"
  done

  for S in owner ops builder; do
    F="$HOME/.claude/skills/$S/SKILL.md"
    [[ -f "$F" ]] || continue
    "$PYTHON" "$LIB" substitute "$F" || warn "substitute failed for $S"
    ok "$S ready"
  done
  phase_done 4
else
  ok "Phase 4 already complete"
fi

# ------------------------------------------------------------------
# Phase 5  —  write config + register install (consumes token)
# ------------------------------------------------------------------
if ! phase_skip 5; then
  say "Phase 5 / 7  —  writing config"
  cat > "$HOME/.founderos/config.json" <<CFG
{
  "tenant_id": "$FOS_TENANT_ID",
  "owner_name": "$FOS_OWNER_NAME",
  "business_name": "$FOS_BUSINESS_NAME",
  "business_slug": "$FOS_BUSINESS_SLUG",
  "supabase_url": "$FOS_SUPABASE_URL",
  "supabase_anon_key": "$FOS_SUPABASE_ANON_KEY",
  "openai_key": "${FOS_OPENAI_KEY:-}",
  "installed_at": "$(date -Iseconds)",
  "version": "$VERSION",
  "admin_url": "$ADMIN_URL"
}
CFG
  chmod 600 "$HOME/.founderos/config.json"

  curl -s -X POST "$ADMIN_URL/rest/v1/rpc/founderos_register_install" \
    -H "apikey: $ADMIN_KEY" -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"p_token\":\"$TOKEN\",\"p_installed_at\":\"$(date -Iseconds)\",\"p_version\":\"$VERSION\"}" \
    >/dev/null || warn "install registration failed (non-fatal)"
  ok "config written + install registered"
  phase_done 5
else
  ok "Phase 5 already complete"
fi

# ------------------------------------------------------------------
# Phase 6  —  heartbeat
# ------------------------------------------------------------------
if ! phase_skip 6; then
  say "Phase 6 / 7  —  channel handshake"
  curl -s -X POST "$ADMIN_URL/rest/v1/founderos_heartbeats" \
    -H "apikey: $ADMIN_KEY" -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"$FOS_TENANT_ID\",\"service\":\"install\",\"status\":\"completed\",\"message\":\"v$VERSION install OK\"}" \
    >/dev/null || warn "heartbeat failed (non-fatal)"
  ok "handshake sent"
  phase_done 6
else
  ok "Phase 6 already complete"
fi

# ------------------------------------------------------------------
# Phase 7  —  done
# ------------------------------------------------------------------
say "Phase 7 / 7  —  install complete"
cat <<DONE

=======================================================
  FounderOS v$VERSION installed for $FOS_BUSINESS_NAME
=======================================================
  Owner:     $FOS_OWNER_NAME
  Supabase:  $FOS_SUPABASE_URL
  Skills:    /owner  /ops  /builder
  Config:    ~/.founderos/config.json

  Next — restart Claude Code, then type:
      /owner

  It starts empty. /owner will guide the intake
  interview. Your answers seed your brain.
=======================================================
DONE
phase_done 7
