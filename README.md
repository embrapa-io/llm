# LLM Stack — GPU Servers da Sede (hp-gpu01 / hp-gpu02)

Stack de inferência LLM dos dois GPU servers "gêmeos" do Data Center da Sede,
derivada de [embrapa-io/ollama](https://github.com/embrapa-io/ollama) (GPU
Server da GTI). Enquanto o server da GTI (Turing, sm_75) exige vLLM e
workarounds, aqui os **L40S (Ada, sm_89)** permitem a stack plena:
**SGLang + FP8 nativo + multimodal + contexto longo (512K–1M)**.

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
│                         ├── SGLang TP=2: Qwen3.6-35B-A3B-FP8
├── GPU 1 (L40S 48 GB) ──┘   multimodal (texto+imagem), 512K de contexto
│                             (YaRN ×2; 1M possível com YaRN ×4)
│
└── CPU (AMX) ──── Ollama: embeddings (bge-m3, qwen3-embedding, ...)

nginx (porta 11434 — URL única para os clientes):
  /v1/*  → SGLang :30000 (OpenAI-compatible: chat, visão, tools)
  /api/* → Ollama :11434 (API nativa: embeddings)
porta 11435 → SGLang direto (diagnóstico)
```

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
docker compose logs -f sglang   # 1º boot: compilação/warmup demora
```

No boot do SGLang, anotar `max_total_num_tokens` (capacidade real de KV) e
validar a relação contexto × slots (`SGLANG_MAX_RUNNING_REQUESTS` no `.env`).

## Endpoints

| Uso | URL |
|---|---|
| Chat/visão/tools (OpenAI-compatible) | `http://hp-gpu0X.nuvem.ti.embrapa.br:11434/v1` |
| Embeddings (API nativa Ollama) | `http://hp-gpu0X.nuvem.ti.embrapa.br:11434/api/embed` |
| SGLang direto (diagnóstico) | `http://hp-gpu0X.nuvem.ti.embrapa.br:11435/v1` |

- Clientes OpenAI usam key dummy (ex.: `sk-local`).
- Thinking: enviar `"chat_template_kwargs": {"enable_thinking": true|false}`
  por request; o raciocínio volta em `reasoning_content` (SGLang).
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

### Rollback para vLLM

O serviço `vllm` fica sob profile (mesma porta do SGLang — não rodam juntos):

```bash
docker compose stop sglang
docker compose --profile vllm up -d vllm
```

No vLLM o raciocínio volta no campo `reasoning` (não `reasoning_content`) e o
YaRN é configurado via `--hf-overrides` (ver `VLLM_EXTRA_ARGS` no compose).

## Validação de contexto longo

Antes de fixar 512K/1M em produção, rodar needle-in-haystack (chave secreta no
meio de um prompt de ≥100K tokens) e conferir recuperação — receita completa na
nota do Obsidian dos GPU Servers da Sede. Com `--kv-cache-dtype fp8_e4m3`
(Ada) a capacidade de KV dobra; validar qualidade antes de adotar.
