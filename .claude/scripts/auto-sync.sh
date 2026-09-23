#!/usr/bin/env bash
# auto-sync.sh · sincronização automática Git ↔ GitHub via Claude Code
#
# VERSÃO CANÔNICA ÚNICA (22/09/2026). Vive em ~/Documents/vantt/.claude/scripts/
# e é copiada para todo repositório Vantt por scripts/sync/propagar-auto-sync.sh.
# Não editar a cópia de um projeto: editar aqui e propagar.
#
# Uso (chamado pelos gatilhos de .claude/settings.json):
#   bash .claude/scripts/auto-sync.sh pull   # traz o GitHub (no máximo 1x a cada 10 min)
#   bash .claude/scripts/auto-sync.sh push   # adiciona, faz commit e envia
#
# Roda igual em macOS (Apple e Intel), Ubuntu/WSL e Windows (Git Bash, que é o
# bash que o Claude Code usa no Windows, inclusive quando aberto pelo PowerShell).
#
# O que ele resolve:
# - Cópia parcial (sparse-checkout): as máquinas da equipe deixam tmp/ e vídeos
#   fora do disco. O "git add ." antigo dava erro nesses caminhos e o script
#   saía sem sincronizar NADA, em silêncio. Aqui o add usa --sparse.
# - Sincroniza o ramo atual, não só a main. Ramo novo sobe com -u.
# - Escolhe um git que de fato roda nesta máquina (binário Intel num Mac Apple
#   falha com "bad CPU type"; o script testa e pula para o próximo).
# - Nunca envia: credenciais (.env, .key, .pem, .p12, credentials*.json,
#   Integracoes/), vídeos (vão para o Drive do cliente) e arquivo acima de 50 MB.
# - Conflito de rebase é desfeito na hora, e o repositório não fica travado.
# - Registra tudo em ~/.claude/logs/auto-sync.log. Nunca interrompe a sessão.

set -uo pipefail

ACTION="${1:-}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
REPO_NAME="$(basename "$PROJECT_DIR")"
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/auto-sync.log"
TMP_BASE="${TMPDIR:-/tmp}"
LIMITE_BYTES=$((50 * 1024 * 1024))
PULL_INTERVALO=600

mkdir -p "$LOG_DIR" 2>/dev/null
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$REPO_NAME] [$ACTION] $*" >> "$LOG_FILE" 2>/dev/null; }

# Log com no máximo ~1 MB
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

# ------------------------------------------------------------ git que funciona
GIT=""
for candidato in "$(command -v git 2>/dev/null)" /opt/homebrew/bin/git /usr/bin/git /usr/local/bin/git; do
  [ -n "$candidato" ] && [ -x "$candidato" ] || continue
  if "$candidato" --version >/dev/null 2>&1; then GIT="$candidato"; break; fi
done
[ -n "$GIT" ] || { log "ERRO: nenhum git executável nesta máquina"; exit 0; }
g() { "$GIT" -C "$PROJECT_DIR" "$@"; }

cd "$PROJECT_DIR" 2>/dev/null || exit 0
[ -e .git ] || exit 0

GITDIR="$(g rev-parse --git-dir 2>/dev/null)" || exit 0
case "$GITDIR" in /*|[A-Za-z]:*) ;; *) GITDIR="$PROJECT_DIR/$GITDIR" ;; esac

# Operação manual em andamento: não mexer
if [ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ] || [ -f "$GITDIR/MERGE_HEAD" ] || [ -f "$GITDIR/CHERRY_PICK_HEAD" ]; then
  log "rebase/merge em andamento, nada feito"
  exit 0
fi

BRANCH="$(g symbolic-ref --short HEAD 2>/dev/null)" || { log "HEAD solto, nada feito"; exit 0; }

# ------------------------------------------------------------ trava
LOCKDIR="$TMP_BASE/.vantt-auto-sync-$(echo "$PROJECT_DIR" | cksum | cut -d' ' -f1).lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
    rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rm -rf "$LOCKDIR"' EXIT

FALHA="$GITDIR/vantt-auto-sync-pendente"
marcar_falha() { echo "$(date '+%d/%m %H:%M') $*" > "$FALHA" 2>/dev/null; log "AVISO: $*"; }

remoto_existe() { g ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; }

atualizar() {
  remoto_existe || return 0
  if ! g pull --rebase --autostash --quiet origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
    g rebase --abort >/dev/null 2>&1
    marcar_falha "pull de origin/$BRANCH falhou (conflito ou sem rede). Nada foi perdido, mas precisa resolver à mão"
    return 1
  fi
  return 0
}

case "$ACTION" in
  pull)
    MARCA="$TMP_BASE/.vantt-auto-sync-pull-$(echo "$PROJECT_DIR" | cksum | cut -d' ' -f1)"
    if [ -f "$MARCA" ]; then
      AGORA=$(date +%s)
      QUANDO=$(stat -f %m "$MARCA" 2>/dev/null || stat -c %Y "$MARCA" 2>/dev/null || echo 0)
      [ $((AGORA - QUANDO)) -lt $PULL_INTERVALO ] && exit 0
    fi
    touch "$MARCA" 2>/dev/null
    atualizar && log "pull ok ($BRANCH)"
    # No início da sessão (gatilho SessionStart) o que sai aqui entra no
    # contexto do Claude, que avisa a pessoa. Sem isso a falha ficaria muda.
    if [ -f "$FALHA" ]; then
      echo "ATENÇÃO (sincronização automática de $REPO_NAME): $(cat "$FALHA"). Detalhes em ~/.claude/logs/auto-sync.log. Avise a pessoa e ajude a resolver antes de seguir."
    fi
    ;;

  push)
    # 1. Preparar o commit
    if [ -n "$(g status --porcelain 2>/dev/null)" ]; then
      g add --sparse -A >>"$LOG_FILE" 2>&1 || g add -A >>"$LOG_FILE" 2>&1 || true

      FORA=""
      while IFS= read -r -d '' st && IFS= read -r -d '' f; do
        motivo=""
        # Credencial só é barrada quando é arquivo NOVO: as já versionadas de
        # propósito (ex.: scripts/env/equipe.env) continuam sincronizando.
        [ "$st" = "A" ] && case "$f" in
          *.env|*.env.*|*.key|*.pem|*.p12|*credentials*.json|Integracoes/*|*/Integracoes/*) motivo="credencial nova" ;;
        esac
        [ -z "$motivo" ] && case "$f" in
          *.mp4|*.MP4|*.mov|*.MOV|*.avi|*.mkv|*.webm|*.m4v|*.mpg|*.mxf) motivo="vídeo (vai para o Drive do cliente)" ;;
        esac
        if [ -z "$motivo" ] && [ -f "$f" ] && [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -gt "$LIMITE_BYTES" ]; then
          motivo="acima de 50 MB"
        fi
        if [ -n "$motivo" ]; then
          g reset -q HEAD -- "$f" >/dev/null 2>&1 || g rm -q --cached -- "$f" >/dev/null 2>&1
          FORA="$FORA
  $f ($motivo)"
        fi
      done < <(g diff --cached --name-status --diff-filter=AM -z 2>/dev/null)
      [ -n "$FORA" ] && log "fora do envio:$FORA"

      if [ -n "$(g diff --cached --name-only 2>/dev/null)" ]; then
        QUEM="$(g config user.name 2>/dev/null || whoami)"
        if g commit --quiet -m "chore(auto-sync): $(date '+%Y-%m-%d %H:%M') via Claude Code ($QUEM)" >>"$LOG_FILE" 2>&1; then
          log "commit ok ($BRANCH)"
        else
          marcar_falha "commit automático falhou"
        fi
      fi
    fi

    # 2. Enviar (inclui commits feitos à mão que ainda não subiram)
    if g fetch --quiet origin "$BRANCH" >/dev/null 2>&1; then
      [ "$(g rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 1)" = "0" ] && { rm -f "$FALHA"; exit 0; }
      atualizar || exit 0
    fi
    for tentativa in 1 2; do
      if g push --quiet -u origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
        log "push ok ($BRANCH)"; rm -f "$FALHA"
        [ "$BRANCH" = "main" ] || log "aviso: ramo $BRANCH não é a main; o resto da equipe só vê depois do merge"
        exit 0
      fi
      [ "$tentativa" = "1" ] && { atualizar || break; }
    done
    marcar_falha "push de $BRANCH falhou; o trabalho ficou só nesta máquina"
    ;;

  *)
    echo "Uso: $0 {pull|push}" >&2
    ;;
esac
exit 0
