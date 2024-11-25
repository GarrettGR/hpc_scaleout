#!/bin/bash

set -o vi

export SLURM_TESTSUITE_SLURMRESTD_URL=http://rest/
export SLURMRESTD_SECURITY=disable_user_check

alias testsuite='cd /usr/local/src/slurm/testsuite/'
