#!/bin/bash

set -euo pipefail

github_prefix='github_''pat_'
classic_prefix='gh''[pousr]_'
token_pattern="(${github_prefix}[A-Za-z0-9_]{20,}|${classic_prefix}[A-Za-z0-9_]{20,})"
private_key_pattern='BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'

if rg --hidden --line-number --color never \
  --glob '!.git/**' \
  --glob '!.build/**' \
  --glob '!Gateway/node_modules/**' \
  --glob '!scripts/check-secrets.sh' \
  --regexp "$token_pattern|$private_key_pattern" .; then
  echo "Potential credential material found. Remove it before committing." >&2
  exit 1
fi
