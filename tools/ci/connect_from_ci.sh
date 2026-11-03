# Sourced by tools/ci/publish_from_ci.sh and tools/ci/next_version.sh: a
# GitHub Actions job's way to Applications Server, with its OIDC token in
# place of a password (AttilaTheFun/applications' docs/CI.md). A repository
# that copies either script copies this file beside it. bash (3.2 or
# later), curl and openssl, on a Mac or Linux. Copied from
# AttilaTheFun/reviews' tools/ci/connect_from_ci.sh.
#
# connect_from_ci sets
# - `token`: the job's token, for the server's audience, masked in the log;
# - `server`: the first of the CI code's addresses that answers and presents
#   the code's certificate authority, which is kept in "$work/ca.pem" for
#   curl to trust alone (`--cacert "$work/ca.pem"`).
# It needs the script's `fail` and `work` (a folder this job alone reads),
# and from the job's environment:
# - its `permissions: id-token: write`, which gives it
#   ACTIONS_ID_TOKEN_REQUEST_URL and ACTIONS_ID_TOKEN_REQUEST_TOKEN;
# - APPLICATIONS_CI_CODE: `applications-server code --ci` (a repository
#   secret): the server's addresses and its certificate authority's
#   fingerprint, which the authority the server presents must match;
# - APPLICATIONS_AUDIENCE: the audience the server takes, if not
#   `applications-server` (`applications-server oidc`).
connect_from_ci() {
  local ci_code json ca addresses audience address host_port fingerprint
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] \
    || fail "no OIDC token to ask for: the job needs permissions: id-token: write"
  [ -n "${APPLICATIONS_CI_CODE:-}" ] || fail "no APPLICATIONS_CI_CODE: applications-server code --ci, on the server's Mac, as a secret"

  # The CI code: base64url of {"addresses":[…],"ca":"<sha-256>","v":1}.
  ci_code="$(printf '%s' "$APPLICATIONS_CI_CODE" | tr -d ' \n' | tr '_-' '/+')"
  while [ $(( ${#ci_code} % 4 )) -ne 0 ]; do ci_code="$ci_code="; done
  json="$(printf '%s' "$ci_code" | base64 --decode 2>/dev/null)" || fail "APPLICATIONS_CI_CODE is not a CI code"
  ca="$(printf '%s' "$json" | sed -n 's/.*"ca":"\([0-9a-f]\{64\}\)".*/\1/p')"
  addresses="$(printf '%s' "$json" | sed -n 's/.*"addresses":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | tr -d '"')"
  [ -n "$ca" ] && [ -n "$addresses" ] || fail "APPLICATIONS_CI_CODE is not a CI code"

  # The job's token, for the server's audience, from GitHub's endpoint. The
  # request's token and the job's are kept in files this job alone reads,
  # never on a command line, and the job's is masked in the log.
  audience="${APPLICATIONS_AUDIENCE:-applications-server}"
  printf 'Authorization: bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" > "$work/request"
  curl -sS --fail --max-time 30 -H @"$work/request" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$audience" -o "$work/token.json" \
    || fail "GitHub gave no OIDC token"
  token="$(sed -n 's/.*"value" *: *"\([^"]*\)".*/\1/p' "$work/token.json")"
  [ -n "$token" ] || fail "GitHub's answer has no token"
  echo "::add-mask::$token"

  # The first address that answers, and the certificate authority it
  # presents (the last certificate of its chain), held to the code's
  # fingerprint: from then on curl trusts that authority alone.
  server=""
  for address in $addresses; do
    curl -sk --connect-timeout 5 --max-time 10 -o /dev/null "$address/api/hello" || continue
    host_port="${address#https://}"
    host_port="${host_port%%/*}"
    # An address openssl can't reach (macOS's local network privacy can
    # let curl through and not openssl) is passed over for the next: under
    # `set -e -o pipefail` its failure would end the script here.
    if ! { openssl s_client -connect "$host_port" -showcerts </dev/null 2>/dev/null || true; } \
      | awk '/-----BEGIN CERTIFICATE-----/ { block = ""; inside = 1 }
             inside { block = block $0 "\n" }
             /-----END CERTIFICATE-----/ { inside = 0; last = block }
             END { printf "%s", last }' > "$work/ca.pem" || [ ! -s "$work/ca.pem" ]; then
      echo "$(basename "$0" .sh): $address presents no certificate to openssl; not used" >&2
      continue
    fi
    fingerprint="$( { openssl x509 -in "$work/ca.pem" -outform DER 2>/dev/null || true; } | openssl dgst -sha256 | sed 's/.*= *//' | tr 'A-F' 'a-f')"
    if [ "$fingerprint" = "$ca" ]; then
      server="$address"
      break
    fi
    echo "$(basename "$0" .sh): $address presents another certificate authority than the code's; not used" >&2
  done
  [ -n "$server" ] || fail "Applications Server answers at none of its addresses ($(echo $addresses))"
}
