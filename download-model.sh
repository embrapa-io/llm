#!/bin/bash
#
# Baixa um modelo do HuggingFace Hub para o diretório configurado em
# SGLANG_MODEL_PATH (.env). Usa o container oficial do huggingface_hub, então
# não exige Python/pip no host.
#
# Uso:
#   ./download-model.sh                              # usa SGLANG_MODEL_REPO + SGLANG_MODEL_PATH do .env
#   ./download-model.sh Qwen/Qwen3.6-27B-FP8 /data/models/meu-modelo
#
# HF_TOKEN: lido do .env ou do ambiente. Se vazio e o terminal for interativo,
# o script pergunta (obter em https://huggingface.co/settings/tokens).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Extrai um único valor do .env sem `source` (vars podem conter espaços e
# tokens como `--flag`, que o bash tentaria executar como comando).
# O `|| true` protege do pipefail: chave ausente/comentada faz o grep retornar
# 1, o que sob `set -euo pipefail` mataria o script silenciosamente.
get_env() {
  local key="$1"
  [[ -f .env ]] || return 0
  { grep -E "^${key}=" .env || true; } | tail -1 | sed -E "s/^${key}=//; s/^[\"'](.*)[\"']\$/\\1/"
}

REPO_ID="${1:-$(get_env SGLANG_MODEL_REPO)}"
REPO_ID="${REPO_ID:-Qwen/Qwen3.6-35B-A3B-FP8}"

TARGET_DIR="${2:-$(get_env SGLANG_MODEL_PATH)}"
TARGET_DIR="${TARGET_DIR:-/data/models/qwen3.6-35b-a3b-fp8}"

HF_TOKEN="${HF_TOKEN:-$(get_env HF_TOKEN)}"

echo "→ Repositório: $REPO_ID"
echo "→ Destino:     $TARGET_DIR"

# Pede HF_TOKEN se vazio e estivermos em terminal interativo.
if [[ -z "${HF_TOKEN:-}" && -t 0 ]]; then
  echo
  echo "HF_TOKEN não definido. Sem ele o HuggingFace aplica rate-limit agressivo"
  echo "e modelos gated falham. Obtenha um token 'Read' em:"
  echo "  https://huggingface.co/settings/tokens"
  read -r -s -p "HF_TOKEN (deixe vazio para seguir sem autenticação): " HF_TOKEN
  echo
  export HF_TOKEN
fi

if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "⚠️  Baixando sem autenticação — sujeito a rate-limit."
fi

mkdir -p "$TARGET_DIR"

# HF_XET_HIGH_PERFORMANCE=1 acelera downloads grandes (substitui o antigo
# HF_HUB_ENABLE_HF_TRANSFER, descontinuado no huggingface_hub 1.x). Flags de
# pip silenciam o aviso de versão e o warning de root.
docker run --rm \
  -v "$TARGET_DIR:/model" \
  -e HF_XET_HIGH_PERFORMANCE=1 \
  -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
  -e PIP_ROOT_USER_ACTION=ignore \
  ${HF_TOKEN:+-e HF_TOKEN="$HF_TOKEN"} \
  python:3.12-slim \
  bash -c "pip install --quiet --no-cache-dir 'huggingface_hub[hf_xet]>=1.0' && \
           hf download '$REPO_ID' --local-dir /model"

echo
echo "✓ Modelo pronto em $TARGET_DIR"
echo "  Ajuste SGLANG_MODEL_PATH e SGLANG_SERVED_MODEL_NAME no .env se necessário."
echo "  Depois: docker compose up -d --force-recreate sglang"
