#!/bin/bash
#
# Encaminhamento de portas para um dos GPU servers da Sede (hp-gpu01/hp-gpu02).
# Diferente do server da GTI, o acesso SSH é direto (sem saltos) — o túnel
# expõe localmente a 11434 (nginx: /v1 GPU + /api Ollama) e a 11435 (SGLang
# direto), útil quando o firewall filtra essas portas para a estação.
#
# Uso:
#   ./tunnel.sh [hp-gpu01|hp-gpu02]   # abre (idempotente) e testa /v1/models
#   ./tunnel.sh down                  # encerra
#   ./tunnel.sh status                # verifica túnel + endpoint

set -euo pipefail

HOST="${1:-hp-gpu01}"
CTRL="${HOME}/.ssh/ctl-llm-tunnel.sock"

is_up() { ssh -O check -S "$CTRL" dummy 2>/dev/null; }

probe() {
  echo "→ GET http://localhost:11435/v1/models"
  curl -sf --max-time 5 "http://localhost:11435/v1/models" && echo || {
    echo "✗ endpoint não respondeu (túnel ok ≠ SGLang no ar — conferir logs no servidor)"
    return 1
  }
}

case "$HOST" in
  down)
    is_up && ssh -O exit -S "$CTRL" dummy 2>/dev/null || true
    echo "✓ túnel encerrado"
    ;;
  status)
    if is_up; then echo "✓ túnel ativo"; probe; else echo "✗ túnel inativo"; fi
    ;;
  hp-gpu01|hp-gpu02)
    if is_up; then
      echo "✓ túnel já ativo"
    else
      ssh -f -N -M -S "$CTRL" \
        -L 11434:localhost:11434 \
        -L 11435:localhost:11435 \
        "$HOST"
      echo "✓ túnel aberto para $HOST (11434 nginx, 11435 SGLang)"
    fi
    probe
    ;;
  *)
    echo "Uso: $0 [hp-gpu01|hp-gpu02|down|status]" >&2
    exit 1
    ;;
esac
