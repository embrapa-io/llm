#!/bin/bash

# nvidia-smi é injetado em qualquer container pelo nvidia-container-runtime —
# não precisa de imagem CUDA. `watch` vem no procps do ubuntu.
docker run --rm -it --runtime=nvidia --gpus all ubuntu:24.04 watch -n 1 nvidia-smi
