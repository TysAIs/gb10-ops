#!/usr/bin/env bash
# Privacy scan for this repository: no site data, no personal data.
#
#   bash tests/purity-scan.sh
#
# Scans every tracked file for the things an operator's repo must never
# carry: private or routable IP literals outside the documentation ranges,
# MAC addresses, email addresses that are not GitHub noreply ones, home
# directories with a real user name, phone numbers, and key material.
#
# Exit 0 when the tree is clean, 1 when anything is found, 2 on setup error.
# Nothing here is configurable by design: a scanner that takes an exception
# list is how a leak gets waved through. If a legitimate line trips it, use a
# documentation-range address or a placeholder instead.
#
# Documentation ranges allowed by RFC 5737: 192.0.2.0/24, 198.51.100.0/24,
# 203.0.113.0/24. Loopback 127.0.0.1 and 0.0.0.0 are allowed because they
# name this machine, not a site.
#
# Git history is scanned separately and reported as advisory: existing
# author identities cannot be changed without rewriting history, and that is
# an owner decision, not something a contributing agent does.

set -u
cd "$(dirname "$0")/.." || exit 2
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not a git checkout" >&2; exit 2; }

hits=0
files=$(git ls-files | wc -l)
echo "scan tree: $files tracked files"

private_re='\b(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|169\.254\.[0-9]{1,3}\.[0-9]{1,3})\b'
mac_re='\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b'
mail_re='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
home_re='(/home|/Users)/[A-Za-z][A-Za-z0-9._-]*'
key_re='BEGIN ([A-Z]+ )?PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}'
phone_re='\+1[-. ][0-9]{3}[-. ][0-9]{3}[-. ][0-9]{4}'

check() { # name regex [allow-regex]
    local name=$1 re=$2 allow=${3:-}
    local out
    out=$(git grep -nEI -- "$re" 2>/dev/null)
    if [ -n "$allow" ] && [ -n "$out" ]; then
        out=$(printf '%s\n' "$out" | grep -vE -- "$allow")
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed "s/^/  $name: /" | head -20
        n=$(printf '%s\n' "$out" | wc -l)
        echo "$name $n hit(s)"
        hits=$((hits+1))
    else
        echo "$name 0 hits"
    fi
}

check ip-private   "$private_re"
check mac          "$mac_re"
check email        "$mail_re"   'noreply@github\.com|users\.noreply\.github\.com'
check home-path    "$home_re"
check key-material "$key_re"
check phone        "$phone_re"

# Every remaining IPv4 literal must be in a documentation range or loopback.
other_ip=$(git grep -hEoI -- '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null \
    | grep -vEx '127\.0\.0\.1|0\.0\.0\.0' \
    | grep -vE '^(192\.0\.2|198\.51\.100|203\.0\.113)\.' | sort -u)
if [ -n "$other_ip" ]; then
    printf '%s\n' "$other_ip" | sed 's/^/  ip-outside-doc-ranges: /'
    echo "ip-outside-doc-ranges $(printf '%s\n' "$other_ip" | wc -l) hit(s)"
    hits=$((hits+1))
else
    echo "ip-outside-doc-ranges 0 hits"
fi

# Advisory: author identities in history. A non-noreply identity is not a
# leak in itself, but it is the operator's decision whether it should be
# rewritten, so this reports and never fails.
echo ""
echo "history author identities (advisory, not counted):"
git log --all --format='%an <%ae>' | sort -u | sed 's/^/  /' \
    | awk '!/users\.noreply\.github\.com|noreply@github\.com/ {print}'

echo ""
if [ "$hits" -eq 0 ]; then
    echo "RESULT: clean (tree)"
    exit 0
fi
echo "RESULT: $hits check(s) found something; fix the tree, do not add exceptions"
exit 1
