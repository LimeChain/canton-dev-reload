#!/bin/bash
# QuickStart's console entrypoint, but runs /fred/fred.canton non-interactively and exits.
set -eou pipefail
generate_jwt() { jwt-cli encode hs256 --s unsafe --p '{"sub": "'"$1"'", "aud": "'"$2"'"}'; }
export APP_PROVIDER_VALIDATOR_USER_TOKEN=$(generate_jwt "$AUTH_APP_PROVIDER_VALIDATOR_USER_NAME" "$AUTH_APP_PROVIDER_AUDIENCE")
export APP_USER_VALIDATOR_USER_TOKEN=$(generate_jwt "$AUTH_APP_USER_VALIDATOR_USER_NAME" "$AUTH_APP_USER_AUDIENCE")
export SV_VALIDATOR_USER_TOKEN=$(generate_jwt "$AUTH_SV_VALIDATOR_USER_NAME" "$AUTH_SV_AUDIENCE")
for script in /app/pre-startup/on/*.sh; do [ -f "$script" ] && source "$script"; done
# OAuth2 mode: the Ledger API only accepts Keycloak-issued tokens, so use the ones run.sh fetched.
# Applied after the pre-startup scripts: those fetch with curl, which this image lacks, and leave it empty.
[ -n "${FRED_PROVIDER_TOKEN:-}" ] && export APP_PROVIDER_VALIDATOR_USER_TOKEN="$FRED_PROVIDER_TOKEN"
[ -n "${FRED_USER_TOKEN:-}" ] && export APP_USER_VALIDATOR_USER_TOKEN="$FRED_USER_TOKEN"
exec /app/bin/canton run /fred/fred.canton --no-tty -c /app/app.conf
