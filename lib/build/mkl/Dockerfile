# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This image contains a single /opt directory and is intended to be COPYed into
# other images. It does not have an entrypoint, and cannot be run by itself.

ARG _MKL_VER

FROM debian:buster-slim as builder
ARG _MKL_VER
WORKDIR /root
COPY build_mkl.sh .
RUN exec ./build_mkl.sh
COPY /etc /opt/etc

FROM scratch
ARG _MKL_VER
CMD []
LABEL version.mkl=$_MKL_VER
COPY --from=builder /opt /opt
