#!/usr/bin/env bash
# Tests for geo-guard.sh, the UserPromptSubmit hook that blocks a prompt when the country
# of the external IP is not in the allowed list. No network is needed: curl is replaced by a shim.
set -uo pipefail

GUARD="$(cd "$(dirname "$0")/.." && pwd)/bin/geo-guard.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else fail "$d" "failed: $*"; fi; }

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  export XDG_RUNTIME_DIR="$TMP/run"
  export GEO_STATE_DIR="$XDG_RUNTIME_DIR/claude-geo-guard"
  export GEO_ALLOWED='DE LT PL NL'
  export GEO_IP_TTL=0   # old tests: ask for the IP on every prompt
  export GEO_IPS_FILE="$TMP/allowed-ips"   # list of allowed IPs; there is no file by default
  mkdir -p "$HOME" "$TMP/bin" "$TMP/net"
  : > "$TMP/curl.log"

  # curl shim: answers for the service named in the URL with the file $TMP/net/<name>; with no file
  # or with <name>.fail it exits 22, like `curl -f` on an error; every call writes the URL to a log
  cat > "$TMP/bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
url=''
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
echo "$url" >> "$FAKE_NET/../curl.log"
case "$url" in
  *icanhazip.com*) name=ip1 ;;
  *api.ipify.org*) name=ip2 ;;
  *ipinfo.io*)     name=geo1 ;;
  *ip-api.com*)    name=geo2 ;;
  *) exit 6 ;;
esac
[ -e "$FAKE_NET/$name.fail" ] && exit 22
[ -e "$FAKE_NET/$name" ] || exit 22
cat "$FAKE_NET/$name"
CURL_EOF
  chmod +x "$TMP/bin/curl"
  export FAKE_NET="$TMP/net"
  export PATH="$TMP/bin:$PATH"

  net ip1 '203.0.113.7'
}
teardown() { rm -rf "$TMP"; }
run_test() { printf '%s\n' "$1"; setup; "$2"; teardown; }

net()  { printf '%s' "$2" > "$TMP/net/$1"; rm -f "$TMP/net/$1.fail"; } # net <name> <answer>
down() { : > "$TMP/net/$1.fail"; }                                      # down <name>
calls() { grep -c "$1" "$TMP/curl.log"; }                              # calls <part of the URL>

fire() { # fire -> RC, ERR
  ERR="$(jq -nc '{hook_event_name:"UserPromptSubmit", session_id:"s1", prompt:"hi"}' \
    | "$GUARD" 2>&1 >/dev/null)"
  RC=$?
}

# --- 1. allowed country -------------------------------------------------------
t_allowed() {
  net geo1 'PL'
  fire
  check "exit 0"        test "$RC" -eq 0
  check "stderr is empty" test -z "$ERR"
  check "the IP and the country are in the cache" grep -qx '203.0.113.7 PL' "$GEO_STATE_DIR/country"
}

# --- 2. forbidden country -----------------------------------------------------
t_blocked() {
  net geo1 'BY'
  fire
  check "exit 2"                       test "$RC" -eq 2
  check "the country is named" grep -q 'BY' <<<"$ERR"
  check "the allowed list is named" grep -q 'DE LT PL NL' <<<"$ERR"
}

# --- 3. the first service is down, the fallback answers -----------------------
t_geo_fallback() {
  down geo1; net geo2 'DE'
  fire
  check "exit 0"                  test "$RC" -eq 0
  check "the fallback service was called" test "$(calls ip-api.com)" -eq 1
}

# --- 4. both geo services are down --------------------------------------------
t_geo_both_down() {
  down geo1; down geo2
  fire
  check "exit 2"                     test "$RC" -eq 2
  check "says that the check could not be done" grep -q 'Could not check' <<<"$ERR"
  check "the failure is not cached" test ! -e "$GEO_STATE_DIR/country"
}

# --- 5. garbage from a geo service = failure, use the fallback ----------------
t_geo_garbage() {
  local bad
  for bad in '<html>' 'Germany' '' 'de' 'DEU'; do
    rm -rf "$GEO_STATE_DIR"; : > "$TMP/curl.log"
    net geo1 "$bad"; net geo2 'DE'
    fire
    check "«$bad» is a failure, the fallback gave DE" test "$RC" -eq 0 -a "$(calls ip-api.com)" -eq 1
  done
}

# --- 6. newline and space in the answer ---------------------------------------
t_trailing_ws() {
  printf 'DE \n' > "$TMP/net/geo1"
  fire
  check "exit 0" test "$RC" -eq 0
  check "the cache holds a clean country" grep -qx '203.0.113.7 DE' "$GEO_STATE_DIR/country"
}

# --- 7. same IP: the geo service is not called a second time ------------------
t_same_ip_cached() {
  net geo1 'DE'
  fire; fire
  check "exit 0"                        test "$RC" -eq 0
  check "the IP was asked on every prompt" test "$(calls icanhazip.com)" -eq 2
  check "the geo service was called once" test "$(calls ipinfo.io)" -eq 1
}

# --- 8. the IP changed: call the geo service again ----------------------------
t_ip_changed() {
  net geo1 'DE'
  fire
  net ip1 '198.51.100.9'; net geo1 'BY'
  fire
  check "exit 2"                          test "$RC" -eq 2
  check "the geo service was called twice" test "$(calls ipinfo.io)" -eq 2
  check "the new country is named" grep -q 'BY' <<<"$ERR"
}

# --- 9. the geo request uses the IP from step 1 -------------------------------
t_geo_gets_ip() {
  net geo1 'DE'
  fire
  check "ipinfo.io was asked about this IP" grep -q 'ipinfo.io/203.0.113.7/country' "$TMP/curl.log"
  rm -rf "$GEO_STATE_DIR"; : > "$TMP/curl.log"
  down geo1; net geo2 'DE'
  fire
  check "ip-api.com was asked about this IP" grep -q 'ip-api.com/line/203.0.113.7' "$TMP/curl.log"
}

# --- 10. external IP services -------------------------------------------------
t_ip_services() {
  net geo1 'DE'
  down ip1; net ip2 '198.51.100.9'
  fire
  check "the fallback IP service worked" test "$RC" -eq 0
  check "the geo request uses its IP" grep -q 'ipinfo.io/198.51.100.9/country' "$TMP/curl.log"

  rm -rf "$GEO_STATE_DIR"; : > "$TMP/curl.log"
  net ip1 '<html>'; net ip2 '198.51.100.9'
  fire
  check "garbage IP: use the fallback service" test "$RC" -eq 0 -a "$(calls api.ipify.org)" -eq 1

  rm -rf "$GEO_STATE_DIR"; : > "$TMP/curl.log"
  down ip1; down ip2
  fire
  check "both IP services are down: exit 2" test "$RC" -eq 2
  check "says that the check could not be done" grep -q 'Could not check' <<<"$ERR"
  check "the geo service was not called" test "$(calls ipinfo.io)" -eq 0
}

# --- 11. IPv6 ----------------------------------------------------------------
t_ipv6() {
  net ip1 '2a01:4f8::1'; net geo1 'DE'
  fire
  check "IPv6 is accepted" test "$RC" -eq 0
  check "the geo request uses the IPv6 address" grep -q 'ipinfo.io/2a01:4f8::1/country' "$TMP/curl.log"
}

# --- 12. a block is not cached: after the VPN is fixed the next prompt passes ---
t_block_not_cached() {
  net geo1 'BY'
  fire
  check "the first prompt is blocked" test "$RC" -eq 2
  check "the block is not written to the cache" test ! -e "$GEO_STATE_DIR/country"
  net geo1 'DE'
  fire
  check "passes after the fix" test "$RC" -eq 0
  check "the geo service was called again" test "$(calls ipinfo.io)" -eq 2
}

# --- 13. GEO_ALLOWED overrides the list ---------------------------------------
t_allowed_override() {
  export GEO_ALLOWED='US'
  net geo1 'DE'
  fire
  check "DE is not in the list US: exit 2" test "$RC" -eq 2
  check "the message shows the list US" grep -q '(US)' <<<"$ERR"
  rm -rf "$GEO_STATE_DIR"
  net geo1 'US'
  fire
  check "US passes"          test "$RC" -eq 0
}

# --- 14. a cached DE does not pass after the list changes ---------------------
t_cache_rechecked_against_list() {
  net geo1 'DE'
  fire
  export GEO_ALLOWED='US'
  fire
  check "the cached country is checked against the current list" test "$RC" -eq 2
}

# --- 15. curl is not in PATH: fail closed -------------------------------------
t_no_curl() {
  local t; mkdir -p "$TMP/tools"
  for t in cat mkdir mv rm tr sed grep head; do ln -s "$(command -v "$t")" "$TMP/tools/$t"; done
  ERR="$(echo '{}' | PATH="$TMP/tools" "$(command -v bash)" "$GUARD" 2>&1 >/dev/null)"
  RC=$?
  check "exit 2"                          test "$RC" -eq 2
  check "says that the check could not be done" grep -q 'Could not check' <<<"$ERR"
}

# --- 16. IP cache TTL: a fresh cache means no network calls -------------------
t_ttl_fresh_skips_ip() {
  export GEO_IP_TTL=60
  net geo1 'DE'
  fire; fire
  check "exit 0"                          test "$RC" -eq 0
  check "the IP service was called once" test "$(calls icanhazip.com)" -eq 1
  check "the geo service was called once" test "$(calls ipinfo.io)" -eq 1
}

# --- 17. TTL expired: ask for the IP again, the time is renewed ---------------
t_ttl_expired_rechecks_ip() {
  export GEO_IP_TTL=60
  net geo1 'DE'
  fire
  touch -d '2 minutes ago' "$GEO_STATE_DIR/country"
  fire
  check "the IP was asked again" test "$(calls icanhazip.com)" -eq 2
  check "the geo service was not called again" test "$(calls ipinfo.io)" -eq 1
  fire
  check "the time is renewed: the third prompt uses no network" test "$(calls icanhazip.com)" -eq 2
}

# --- 18. TTL expired and the IP changed: block --------------------------------
t_ttl_expired_ip_changed() {
  export GEO_IP_TTL=60
  net geo1 'DE'
  fire
  touch -d '2 minutes ago' "$GEO_STATE_DIR/country"
  net ip1 '198.51.100.9'; net geo1 'BY'
  fire
  check "exit 2"                          test "$RC" -eq 2
  check "the new country is named" grep -q 'BY' <<<"$ERR"
}

# --- 19. a fresh cache is checked against the current country list ------------
t_ttl_fresh_rechecked_against_list() {
  export GEO_IP_TTL=60
  net geo1 'DE'
  fire
  export GEO_ALLOWED='US'
  fire
  check "a fresh cache does not bypass the list" test "$RC" -eq 2
}

# --- 20. the default TTL is 60 seconds ----------------------------------------
t_ttl_default_60() {
  unset GEO_IP_TTL
  net geo1 'DE'
  fire
  touch -d '30 seconds ago' "$GEO_STATE_DIR/country"
  fire
  check "after 30 s: no network"        test "$(calls icanhazip.com)" -eq 1
  touch -d '90 seconds ago' "$GEO_STATE_DIR/country"
  fire
  check "after 90 s: the IP is asked again" test "$(calls icanhazip.com)" -eq 2
}

# --- 21. an IP from the list passes without a geo request, even if the country is forbidden ---
t_ip_listed() {
  printf '203.0.113.7\n' > "$GEO_IPS_FILE"
  net geo1 'BY'
  fire
  check "exit 0"                          test "$RC" -eq 0
  check "the geo service was not called" test "$(calls ipinfo.io)" -eq 0
  check "the IP was still asked" test "$(calls icanhazip.com)" -eq 1
  check "the cache holds the IP without a country" grep -qx '203.0.113.7 -' "$GEO_STATE_DIR/country"
}

# --- 22. an IP from the list and a fresh cache: no network --------------------
t_ip_listed_fresh_cache() {
  export GEO_IP_TTL=60
  printf '203.0.113.7\n' > "$GEO_IPS_FILE"
  fire; fire
  check "exit 0"                          test "$RC" -eq 0
  check "the IP service was called once" test "$(calls icanhazip.com)" -eq 1
}

# --- 23. another IP is in the list: the check works as usual ------------------
t_ip_not_listed() {
  printf '198.51.100.9\n' > "$GEO_IPS_FILE"
  net geo1 'BY'
  fire
  check "exit 2"                          test "$RC" -eq 2
  check "the geo service was called" test "$(calls ipinfo.io)" -eq 1
}

# --- 24. comments, empty lines and spaces in the file -------------------------
t_ip_list_format() {
  printf '# my VPS\n\n  198.51.100.9  \n203.0.113.7  # home\n' > "$GEO_IPS_FILE"
  net geo1 'BY'
  fire
  check "the IP is found among the comments" test "$RC" -eq 0
}

# --- 25. the IP is removed from the list: a cache without a country no longer passes ---
t_ip_list_removed() {
  printf '203.0.113.7\n' > "$GEO_IPS_FILE"
  net geo1 'BY'
  fire
  : > "$GEO_IPS_FILE"
  fire
  check "exit 2"                          test "$RC" -eq 2
  check "the country was checked" test "$(calls ipinfo.io)" -eq 1
}

# --- 26. the IP changed: the list does not cover the new IP -------------------
t_ip_listed_then_changed() {
  export GEO_IP_TTL=60
  printf '203.0.113.7\n' > "$GEO_IPS_FILE"
  fire
  touch -d '2 minutes ago' "$GEO_STATE_DIR/country"
  net ip1 '198.51.100.9'; net geo1 'BY'
  fire
  check "exit 2"                          test "$RC" -eq 2
}

run_test "allowed country passes"                 t_allowed
run_test "forbidden country blocks"               t_blocked
run_test "fallback geo service"                   t_geo_fallback
run_test "both geo services are down: block"      t_geo_both_down
run_test "garbage from a geo service is a failure" t_geo_garbage
run_test "space and newline in the answer"        t_trailing_ws
run_test "same IP: no second geo request"         t_same_ip_cached
run_test "IP changed: new geo request"            t_ip_changed
run_test "geo request uses the IP from step 1"    t_geo_gets_ip
run_test "external IP services"                   t_ip_services
run_test "IPv6"                                   t_ipv6
run_test "a block is not cached"                  t_block_not_cached
run_test "GEO_ALLOWED overrides the list"         t_allowed_override
run_test "cache is checked against the current list" t_cache_rechecked_against_list
run_test "no curl: block"                         t_no_curl
run_test "TTL: fresh cache, no network"           t_ttl_fresh_skips_ip
run_test "TTL: expired, ask for the IP again"     t_ttl_expired_rechecks_ip
run_test "TTL: expired and IP changed: block"     t_ttl_expired_ip_changed
run_test "TTL: fresh cache is checked against the list" t_ttl_fresh_rechecked_against_list
run_test "TTL default is 60 s"                    t_ttl_default_60
run_test "IP from the list: no geo request"       t_ip_listed
run_test "IP from the list and fresh cache: no network" t_ip_listed_fresh_cache
run_test "other IP in the list: normal check"     t_ip_not_listed
run_test "format of the IP list file"             t_ip_list_format
run_test "IP removed from the list: checked again" t_ip_list_removed
run_test "IP changed: the list does not apply"    t_ip_listed_then_changed

printf '\ntotal: %d ok, %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
