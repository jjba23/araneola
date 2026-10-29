#!/usr/bin/env bash

# araneola - high-performance web crawler and sitemap generator
#
# SPDX-License-Identifier: MIT
# Copyright © Josep Bigorra <jjbigorra@gmail.com>

set -euo pipefail

bold_text='\033[1m'
red_text='\033[0;31m'
reset_text='\033[0m'

get_timestamp() {
  date '+%Y-%m-%d %H:%M:%S%:z'
}

log_error() {
  if [ -z "${1}" ]; then
    log_error "log-error was called without a message."
    return 1
  fi

  echo -e "${red_text}[ERROR][$(get_timestamp)] ${1}${reset_text}" >&2
}

log_info() {
  if [ -z "${1}" ]; then
    log_error "log-info was called without a message."
    return 1
  fi

  echo -e "${bold_text}[INFO][$(get_timestamp)] ${1}${reset_text}"
}
