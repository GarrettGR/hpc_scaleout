#!/bin/bash

# Set distro / base image
DISTRO_BOOTSTRAP="${DISTRO_BOOTSTRAP:-"docker"}"
DISTRO="${DISTRO:-"almalinux:8"}"

# Set SLURM release/version
SLURM_RELEASE="${SLURM_RELEASE:-master}"
