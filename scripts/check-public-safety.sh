#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

mapfile -d '' tracked_files < <(git ls-files -z)

blocked_paths=()
for path in "${tracked_files[@]}"; do
  basename="${path##*/}"
  lowercase_basename="${basename,,}"
  lowercase_path="${path,,}"

  case "$lowercase_basename" in
    .env|.env.*)
      case "$lowercase_basename" in
        *.example|*.sample|*.template) ;;
        *) blocked_paths+=("$path") ;;
      esac
      ;;
    *.p12|*.pfx|*.p8|*.key|*.pem|*.mobileprovision|*.mobiledevicepairing|*.ipa|*.xcarchive|*.xcresult|*.har|*.log|*.sqlite|*.sqlite-*|*.db|*.realm)
      blocked_paths+=("$path")
      ;;
    cookies.json|credentials.json|account.json|accounts.json|session.json|auth.json|exportoptions.plist)
      blocked_paths+=("$path")
      ;;
    *pairing*.plist|*credential*.plist|*secret*.plist|*secrets*.xcconfig|*local*.xcconfig)
      blocked_paths+=("$path")
      ;;
  esac

  case "$lowercase_path" in
    */xcuserdata/*|*/deriveddata/*|*/webkit/*|*/keychains/*)
      blocked_paths+=("$path")
      ;;
  esac
done

declare -a finding_labels=()
declare -a finding_files=()

check_index() {
  local label="$1"
  local expression="$2"
  local matches=()

  mapfile -d '' matches < <(
    git grep --cached -I -l -z -E "$expression" -- . 2>/dev/null || true
  )

  local path
  for path in "${matches[@]}"; do
    finding_labels+=("$label")
    finding_files+=("$path")
  done
}

# These checks intentionally target high-confidence formats. Credential field names and short,
# obviously synthetic values remain valid in implementation code and unit tests.
check_index "private-key material" '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----'
check_index "GitHub token" '(github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,})'
check_index "AWS access key" '(AKIA|ASIA)[A-Z0-9]{16}'
check_index "Google API key" 'AIza[A-Za-z0-9_-]{35}'
check_index "OpenAI-style API key" 'sk-(proj-)?[A-Za-z0-9_-]{20,}'
check_index "JWT or bearer credential" '(Authorization:|authorization"?[[:space:]]*[:=])[[:space:]]*(Bearer[[:space:]]+)?eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
check_index "long Zhihu session value" '(d_c0|z_c0|_xsrf)"?[[:space:]]*[:=][[:space:]]*"?[^";[:space:]]{32,}'

if (( ${#blocked_paths[@]} == 0 && ${#finding_files[@]} == 0 )); then
  echo "Public-safety check passed: tracked index contains no blocked paths or high-confidence secrets."
  exit 0
fi

echo "Public-safety check failed. Matched values are intentionally not printed." >&2

if (( ${#blocked_paths[@]} > 0 )); then
  echo "Blocked tracked paths:" >&2
  printf '  - %s\n' "${blocked_paths[@]}" | sort -u >&2
fi

if (( ${#finding_files[@]} > 0 )); then
  echo "Potential secret material:" >&2
  for index in "${!finding_files[@]}"; do
    printf '  - %s: %s\n' "${finding_labels[$index]}" "${finding_files[$index]}"
  done | sort -u >&2
fi

cat >&2 <<'EOF'
Remove the data from the Git index and rotate any real credential before continuing. If the data was
already pushed, follow SECURITY.md; deleting it in a later commit is not sufficient.
EOF
exit 1
