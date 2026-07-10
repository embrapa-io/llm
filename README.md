# LLM Stack — GPU Servers da Sede (hp-gpu01 / hp-gpu02)

Stack de inferência LLM dos dois GPU servers "gêmeos" do Data Center da Sede,
derivada de [embrapa-io/ollama](https://github.com/embrapa-io/ollama) (GPU
Server da GTI). Os **L40S (Ada, sm_89)** rodam **FP8 nativo + multimodal +
contexto longo** sem os workarounds de kernel do Turing. Engine padrão:
**vLLM** (TP=2). O SGLang fica sob profile: em 10/07/2026 o boot travava no
primeiro coletivo do TP=2 (GPUs em sockets distintos, topologia `SYS` sem
P2P) — retestar com `NCCL_P2P_DISABLE=1` antes de descartar.

| | |
|---|---|
| **hp-gpu01** | `hp-gpu01.nuvem.ti.embrapa.br` (192.168.180.143) — produção |
| **hp-gpu02** | `hp-gpu02.nuvem.ti.embrapa.br` (192.168.180.144) — desenvolvimento |

Os dois servidores recebem **a mesma configuração** (este repositório). A
distinção produção/desenvolvimento é só de uso e clientela.

## Hardware (idêntico nos dois)

- **Servidor:** HPE ProLiant Compute DL380 Gen12 (bare metal)
- **GPUs:** 2× NVIDIA **L40S 48 GB** (Ada Lovelace, sm_89) — 96 GB de VRAM
  por servidor, **FP8 nativo** (E4M3/E5M2); sem FP4 (exclusivo de Blackwell)
- **CPU:** 2× Intel **Xeon 6730P** (Granite Rapids) — 64 cores/128 threads,
  **AMX** (tiles INT8/BF16 — embeddings em CPU muito rápidos)
- **RAM:** 256 GB DDR5 (4× 64 GB)
- **Disco:** NVMe 447 GB (HPE NS204i-u, RAID1 de boot) — LVM expandido para
  o volume inteiro; controladora MegaRAID SAS39xx presente **sem discos**
- **SO:** Ubuntu 26.04 LTS · driver NVIDIA **R595** (`595-server-open`)

## Arquitetura

```
hp-gpu0X (256 GB RAM, 2× Xeon 6730P)
├── GPU 0 (L40S 48 GB) ──┐
│                         ├── vLLM TP=2: Qwen3.6-35B-A3B-FP8
├── GPU 1 (L40S 48 GB) ──┘   multimodal (texto+imagem), 262K nativo
│                             (KV p/ 2,17M tokens ≈ 8,3× 262K cheios;
│                              512K/1M via YaRN a validar)
│
└── CPU (AMX) ──── Ollama: embeddings (bge-m3, qwen3-embedding, ...)

nginx (porta 11434 — URL única para os clientes):
  /v1/*  → vLLM :8000 (OpenAI-compatible: chat, visão, tools)
  /api/* → Ollama :11434 (API nativa: embeddings)
porta 11435 → engine direto (diagnóstico)
```

⚠️ **Topologia crítica**: cada L40S pende de um socket (domínios PCI
`0000`/`0001`, NUMA 0/1, interligação `SYS`, sem NVLink/P2P). Todo engine
com TP=2 precisa de `NCCL_P2P_DISABLE=1` e all-reduce custom desabilitado —
sem isso o primeiro coletivo trava com GPU a 100% até o watchdog matar o
processo (diagnóstico de 10/07/2026, idêntico em SGLang e vLLM).

## Modelo servido nas GPUs

**[Qwen/Qwen3.6-35B-A3B-FP8](https://huggingface.co/Qwen/Qwen3.6-35B-A3B-FP8)**
(abril/2026, Apache 2.0, ~37 GiB):

- **MoE 35B total / 3B ativos** — throughput de modelo pequeno com qualidade
  de classe 30B+ (SWE-Bench Verified 73,4%, melhor da classe)
- **Multimodal** (early-fusion VLM): texto + imagem no mesmo modelo
- **Atenção híbrida GDN** (Gated DeltaNet na maioria das camadas) — KV cache
  leve, o que torna 512K–1M de contexto viável em 96 GB
- **FP8 fine-grained oficial da Qwen** — nativo em Ada, qualidade ~idêntica
  ao BF16 com metade da VRAM
- Contexto **262K nativo**; 512K/1M via YaRN (configurado no `.env`)
- Thinking per-request (`chat_template_kwargs.enable_thinking`) e tool
  calling (`qwen3_coder`)

Racional da escolha (julho/2026): nada maior com visão cabe em 96 GB FP8 —
GLM-4.7/DeepSeek V4/Kimi K2.6 são 100B+; Gemma 4 26B é classe menor; o
Nemotron-3-Nano (1M nativo) é text-only. O 27B dense da mesma família é a
alternativa de qualidade-por-token (menor throughput): `Qwen/Qwen3.6-27B-FP8`.

## Setup de um servidor do zero

```bash
# 1. Provisionar (driver NVIDIA, Docker CE oficial, NVIDIA Container Toolkit)
sudo bash setup/provision.sh
sudo reboot

# 2. Clonar a stack
sudo mkdir -p /data && sudo chown embrapa:embrapa /data
git clone https://github.com/embrapa-io/llm.git /data/llm
cd /data/llm
cp .env.example .env    # revisar valores

# 3. Rede externa do compose (compartilhável com outras stacks do host)
docker network create llm

# 4. Baixar o modelo (~37 GiB)
./download-model.sh

# 5. Subir
docker compose up -d --build
docker compose logs -f vllm     # boot ~100 s (medido em 10/07/2026)
```

No boot do vLLM, anotar `GPU KV cache size` (tokens) e `Maximum concurrency`
— em 10/07/2026: **2.168.929 tokens** e **8,27×** com requests de 262K.

## Endpoints

| Uso | URL |
|---|---|
| Chat/visão/tools (OpenAI-compatible) | `http://hp-gpu0X.nuvem.ti.embrapa.br/v1` |
| Embeddings (API nativa Ollama) | `http://hp-gpu0X.nuvem.ti.embrapa.br/api/embed` |
| Engine direto (diagnóstico) | `http://hp-gpu0X.nuvem.ti.embrapa.br:11435/v1` |

A porta 80 é o padrão (URL sem porta, HTTP puro — intranet do DC, sem TLS
por decisão da ata GTI de 03/07/2026; terminação TLS futura fica no Kong).
A 11434 segue mapeada por compatibilidade com o padrão do server da GTI.

- Clientes OpenAI usam key dummy (ex.: `sk-local`).
- Thinking: enviar `"chat_template_kwargs": {"enable_thinking": true|false}`
  por request; no vLLM o raciocínio volta no campo `reasoning` (no SGLang
  seria `reasoning_content`) — mesmo comportamento do server da GTI.
- Endpoints de administração do Ollama (`/api/pull`, `/api/delete`, ...) são
  bloqueados no nginx (403) — usar `docker compose exec ollama ollama pull ...`.

## Modelos Ollama (CPU — embeddings)

Curadoria mínima (mesma do server GTI):

```bash
docker compose exec ollama ollama pull bge-m3              # principal (RAG pt-BR)
docker compose exec ollama ollama pull qwen3-embedding:0.6b
docker compose exec ollama ollama pull embeddinggemma:300m
docker compose exec ollama ollama pull granite-embedding:278m
```

## Operação

```bash
./update.sh                      # git pull + rebuild + prune (rotina de update)
./monitor.sh                     # nvidia-smi em loop (via container)
./tunnel.sh hp-gpu01             # da estação: 11434/11435 locais → servidor
docker compose logs -f sglang    # logs do engine
```

### Teste do SGLang (profile)

O serviço `sglang` fica sob profile (mesma porta do vLLM — não rodam juntos).
Antes de testar, garantir `NCCL_P2P_DISABLE=1` (já default no compose) e
trocar o upstream do nginx para `sglang:30000`:

```bash
docker compose stop vllm
docker compose --profile sglang up -d sglang
```

No vLLM o YaRN para >262K é configurado via `--hf-overrides` (usar
`VLLM_EXTRA_ARGS`); no SGLang, via `--json-model-override-args` +
`SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1` (ver `.env.example`).

## Validação de contexto longo

Antes de fixar 512K/1M em produção, rodar needle-in-haystack (chave secreta no
meio de um prompt de ≥100K tokens) e conferir recuperação — receita completa na
nota do Obsidian dos GPU Servers da Sede. Com `--kv-cache-dtype fp8_e4m3`
(Ada) a capacidade de KV dobra; validar qualidade antes de adotar.
