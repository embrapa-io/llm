#!/bin/bash

set -ex

SCRIPT_DIR=$(dirname "$0")

cd "$SCRIPT_DIR"

pwd

git fetch --all

git pull

docker compose pull --ignore-pull-failures --ignore-buildable

docker compose up --build --force-recreate --remove-orphans --wait

# -a: com tags pinadas a imagem antiga não vira dangling após um bump
docker image prune -af

# filtro: não apagar volumes órfãos de outras stacks do host
docker volume prune -f --filter label=com.docker.compose.project=llm

docker builder prune -f
