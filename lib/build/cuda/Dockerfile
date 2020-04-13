# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This image contains a single /opt directory and is intended to be COPYed into
# other images. It does not have an entrypoint, and cannot be run by itself.

ARG _CUDA_VER
ARG _CUDA_SOURCE_URL

FROM debian:buster-slim as builder
ARG _CUDA_VER
ARG _CUDA_SOURCE_URL
WORKDIR /root
COPY build_cuda.sh .
RUN exec ./build_cuda.sh
COPY /etc /opt/etc

FROM scratch
ARG _CUDA_VER
LABEL version.cuda=$_CUDA_VER
CMD []
COPY --from=builder /opt /opt
