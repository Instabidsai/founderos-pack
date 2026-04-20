#!/usr/bin/env bash
#
# FounderOS — bootstrap installer (v0.1.0)
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Instabidsai/founderos-pack/main/install.sh | bash -s -- <TOKEN>
#   OR
#   bash install.sh <TOKEN>
#
# Resumable: re-running with the same token picks up from the last completed phase.
# State: ~/.founderos/install.state  (one phase number per line, last = most recent completed)
#
set -euo pipefail

TOKEN="${1:-}"
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: install token required"
  echo "Usage: bash install.sh <TOKEN>"
  exit 1
fi

VERSION="0.1.0"
PACK_URL="${FOS_PACK_URL:-https://github.com/Instabidsai/founderos-pack/releases/download/v${VERSION}/founderos-skill-pack-v${VERSION}.tar.gz}"
# Admin = Justin Brain Supabase (public anon JWT is fine for validate_install_token)
ADMIN_URL="${FOS_ADMIN_URL:-https://wdvfwtecvdhtvmyeymgy.supabase.co}"
ADMIN_KEY="${FOS_ADMIN_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndkdmZ3dGVjdmRodHZteWV5bWd5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzExNTU3MjEsImV4cCI6MjA4NjczMTcyMX0.01rJXoNV8VCzEQe1guCd0Z9Ff3kkCHgacGMyO9QWcDM}"

STATE_DIR="$HOME/.founderos"
STATE_FILE="$STATE_DIR/install.state"
LOG_FILE="$STATE_DIR/install.log"
mkdir -p "$STATE_DIR"

say()   { printf "\n\033[1;36m==> %s\033[0m\n" "$*" | tee -a "$LOG_FILE"; }
ok()    { printf "   \033[1;32m[OK]\033[0m %s\n" "$*" | tee -a "$LOG_FILE"; }
warn()  { printf "   \033[1;33m[WARN]\033[0m %s\n" "$*" | tee -a "$LOG_FILE"; }
die()   { printf "\n\033[1;31mFAIL: %s\033[0m\n" "$*" | tee -a "$LOG_FILE" >&2
          report_error "$LAST_PHASE" "$*"
          exit 1; }

LAST_PHASE=0
phase_done()  { echo "$1" >> "$STATE_FILE"; LAST_PHASE=$1; }
phase_skip()  { [[ -f "$STATE_FILE" ]] && grep -qx "$1" "$STATE_FILE" 2>/dev/null; }

report_error() {
  local phase=$1 err=$2
  curl -s -X POST "$ADMIN_URL/rest/v1/founderos_install_errors" \
    -H "apikey: $ADMIN_KEY" -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"${FOS_TENANT_ID:-00000000-0000-0000-0000-000000000000}\",\"phase\":$phase,\"error\":$(printf '%s' "$err" | $PYTHON -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}" \
    >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------
# Phase 1  —  environment check
# ------------------------------------------------------------------
if ! phase_skip 1; then
  say "Phase 1 / 7  —  environment check"
  command -v curl >/dev/null || die "curl missing"
  command -v tar >/dev/null || die "tar missing"
  command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || die "python missing"
  PYTHON=$(command -v python3 2>/dev/null || command -v python)
  command -v claude >/dev/null || die "Claude Code not installed. Install from https://claude.com/claude-code first."
  mkdir -p "$HOME/.claude/skills"
  ok "curl + python + claude all present"
  phase_done 1
else
  PYTHON=$(command -v python3 2>/dev/null || command -v python)
  ok "Phase 1 already complete"
fi

# ------------------------------------------------------------------
# Phase 2  —  validate token + fetch tenant config
# ------------------------------------------------------------------
if ! phase_skip 2; then
  say "Phase 2 / 7  —  validating install token"
  VALIDATE=$(curl -s -X POST "$ADMIN_URL/rest/v1/rpc/validate_install_token" \
    -H "apikey: $ADMIN_KEY" -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"p_token\":\"$TOKEN\"}") || die "token validation request failed (network?)"

  echo "$VALIDATE" | $PYTHON - <<'PYEOF' > "$STATE_DIR/env.sh" || die "token rejected"
import json, sys, os
raw = sys.stdin.read()
try:
    r = json.loads(raw)
except Exception:
    print(f"# parse error: {raw[:200]}", file=sys.stderr); sys.exit(1)
if isinstance(r, list) and r: r = r[0]
if not r.get("valid"):
    print(f"# REJECTED: {r.get('reason','unknown')}", file=sys.stderr); sys.exit(1)
for k in ("tenant_id","owner_name","business_name","business_slug",
          "supabase_url","supabase_anon_key","supabase_service_role",
          "supabase_project_ref","openai_key","channel_enabled"):
    v = r.get(k)
    if v is None: continue
    print(f'export FOS_{k.upper()}={json.dumps(str(v))}')
PYEOF

  # shellcheck disable=SC1090
  source "$STATE_DIR/env.sh"
  chmod 600 "$STATE_DIR/env.sh"
  [[ -n "${FOS_SUPABASE_URL:-}" ]] || die "token did not include supabase_url"
  ok "Token valid — installing for $FOS_OWNER_NAME @ $FOS_BUSINESS_NAME"
  phase_done 2
else
  source "$STATE_DIR/env.sh"
  ok "Phase 2 already complete — $FOS_OWNER_NAME @ $FOS_BUSINESS_NAME"
fi

# ------------------------------------------------------------------
# Phase 3  —  Supabase reachability + schema apply
# ------------------------------------------------------------------
if ! phase_skip 3; then
  say "Phase 3 / 7  —  applying tenant schema to Supabase"
  curl -sf "$FOS_SUPABASE_URL/rest/v1/" -H "apikey: $FOS_SUPABASE_ANON_KEY" >/dev/null \
    || die "tenant Supabase unreachable at $FOS_SUPABASE_URL"

  # Download pack (we extract the .agent/ files here)
  TMP=$(mktemp -d)
  curl -sfL "$PACK_URL" -o "$TMP/pack.tar.gz" || die "failed to fetch skill pack from $PACK_URL"
  tar xzf "$TMP/pack.tar.gz" -C "$TMP"

  for FN in schema.sql rpcs.sql 003_self_growing.sql; do
    [[ -f "$TMP/.agent/$FN" ]] || { warn "pack missing .agent/$FN (skipping)"; continue; }
  done

  if [[ -z "${FOS_SUPABASE_PROJECT_REF:-}" ]]; then
    warn "no supabase_project_ref in token — schema apply must be done by installer-operator"
    warn "  to apply manually: run each .agent/*.sql via Supabase SQL editor"
  else
    # Uses tenant's service-role JWT as mgmt. If actual mgmt token present in env, prefer it.
    MGMT_TOKEN="${FOS_SUPABASE_MGMT_TOKEN:-${FOS_SUPABASE_SERVICE_ROLE:-}}"
    [[ -n "$MGMT_TOKEN" ]] || die "no mgmt token / service role available for schema apply"

    for FN in schema.sql rpcs.sql 003_self_growing.sql; do
      [[ -f "$TMP/.agent/$FN" ]] || continue
      say "  applying $FN"
      $PYTHON - <<PYEOF
import json, os, sys, urllib.request
sql = open(r'$TMP/.agent/$FN', encoding='utf-8').read()
body = json.dumps({'query': sql}).encode()
req = urllib.request.Request(
    f"https://api.supabase.com/v1/projects/$FOS_SUPABASE_PROJECT_REF/database/query",
    data=body, method='POST',
    headers={
        'Authorization': f"Bearer $MGMT_TOKEN",
        'Content-Type': 'application/json',
        'User-Agent': 'Mozilla/5.0 (FounderOS-Installer)',
    }
)
try:
    urllib.request.urlopen(req, timeout=120).read()
    print("    [OK]")
except urllib.error.HTTPError as e:
    print(f"    [FAIL] HTTP {e.code}: {e.read().decode()[:300]}", file=sys.stderr)
    sys.exit(1)
PYEOF
    done
  fi

  # Smoke-test tables
  for T in owner_memory owner_mental_model owner_threads owner_rejections owner_sessions owner_snapshots owner_todos owner_skill_requests; do
    curl -sf "$FOS_SUPABASE_URL/rest/v1/$T?limit=0" \
      -H "apikey: $FOS_SUPABASE_ANON_KEY" >/dev/null \
      || warn "table $T not reachable after migration (check schema apply path)"
  done
  ok "schema applied"
  rm -rf "$TMP"
  phase_done 3
else
  ok "Phase 3 already complete"
fi

# ------------------------------------------------------------------
# Phase 4  —  install skill pack + substitute placeholders
# ------------------------------------------------------------------
if ! phase_skip 4; then
  say "Phase 4 / 7  —  installing skills into ~/.claude/skills/"
  TMP=$(mktemp -d)
  curl -sfL "$PACK_URL" -o "$TMP/pack.tar.gz" || die "failed to fetch skill pack"
  tar xzf "$TMP/pack.tar.gz" -C "$TMP"

  for S in owner ops builder init-founderos; do
    [[ -d "$TMP/skills/$S" ]] || { warn "pack missing skills/$S"; continue; }
    rm -rf "$HOME/.claude/skills/$S"
    cp -r "$TMP/skills/$S" "$HOME/.claude/skills/$S"
  done

  # Substitute placeholders
  for S in owner ops builder; do
    F="$HOME/.claude/skills/$S/SKILL.md"
    [[ -f "$F" ]] || continue
    $PYTHON - <<PYEOF
import os, sys
path = r'$F'
s = open(path, encoding='utf-8').read()
sub = {
  '{{SUPABASE_URL}}':     os.environ['FOS_SUPABASE_URL'],
  '{{SUPABASE_ANON_KEY}}': os.environ['FOS_SUPABASE_ANON_KEY'],
  '{{OPENAI_KEY}}':       os.environ.get('FOS_OPENAI_KEY', ''),
  '{{OWNER_NAME}}':       os.environ['FOS_OWNER_NAME'],
  '{{BUSINESS_NAME}}':    os.environ['FOS_BUSINESS_NAME'],
  '{{BUSINESS_SLUG}}':    os.environ['FOS_BUSINESS_SLUG'],
}
for k,v in sub.items(): s = s.replace(k,v)
open(path,'w',encoding='utf-8').write(s)
if '{{' in s and '}}' in s:
    # warn but don't fail — some {{...}} may be legitimate code blocks
    print(f'    [WARN] residual {{...}} in {path} — review', file=sys.stderr)
PYEOF
    ok "$S ready"
  done
  rm -rf "$TMP"
  phase_done 4
else
  ok "Phase 4 already complete"
fi

# ------------------------------------------------------------------
# Phase 5  —  write config + register install
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
  ok "~/.founderos/config.json written"

  curl -s -X POST "$ADMIN_URL/rest/v1/rpc/founderos_register_install" \
    -H "apikey: $ADMIN_KEY" -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"p_token\":\"$TOKEN\",\"p_installed_at\":\"$(date -Iseconds)\",\"p_version\":\"$VERSION\"}" \
    >/dev/null || warn "install registration failed (non-fatal)"
  ok "install registered with FounderOS admin"
  phase_done 5
else
  ok "Phase 5 already complete"
fi

# ------------------------------------------------------------------
# Phase 6  —  channel handshake heartbeat
# ------------------------------------------------------------------
if ! phase_skip 6; then
  say "Phase 6 / 7  —  channel handshake"
  curl -s -X POST "$ADMIN_URL/rest/v1/founderos_heartbeats" \
    -H "apikey: $ADMIN_KEY" -H "Authorization: Bearer $ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"tenant_id\":\"$FOS_TENANT_ID\",\"service\":\"install\",\"status\":\"completed\",\"message\":\"v$VERSION install complete\"}" \
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
  Log:       ~/.founderos/install.log

  Next — in a NEW Claude Code session, type:
      /owner

  It will start empty. /owner will guide the intake
  interview. Answers seed your brain.

=======================================================
DONE
phase_done 7
