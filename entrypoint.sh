#!/usr/bin/dumb-init /bin/bash
set -o errexit -o pipefail

b64enc() { 
  openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'
}

deregister_runner() {
  echo "Caught $1 - Deregistering runner"
  runner_token=$(get_runner_token)
  ./config.sh remove --token "${runner_token}"
  exit
}

get_runner_token() {
  now=$(date +%s)
  iat=$((${now} - 60)) # Issues 60 seconds in the past
  exp=$((${now} + 600)) # Expires 10 minutes in the future

  header_json='{
      "typ":"JWT",
      "alg":"RS256"
  }'
  # Header encode
  header=$(echo -n "${header_json}" | b64enc)

  payload_json='{
      "iat":'"${iat}"',
      "exp":'"${exp}"',
      "iss":'"\"${APP_CLIENT_ID}\""'
  }'
  # Payload encode
  payload=$(echo -n "${payload_json}" | b64enc)

  # Signature
  header_payload="${header}"."${payload}"
  signature=$(
      openssl dgst -sha256 -sign <(echo -n "${APP_PRIVATE_KEY}") \
      <(echo -n "${header_payload}") | b64enc
  )

  # Create JWT
  jwt="${header_payload}"."${signature}"

  app_token=$(curl --request POST --silent \
    --url "${API_URI}/app/installations/${APP_INSTALLATION_ID}/access_tokens" \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${jwt}" \
    --header "X-GitHub-Api-Version: 2022-11-28" | jq -r .token)

  if [[ -z ${app_token} ]]; then
    echo "ERROR: Failed to get an app token." >&2
    exit 1
  fi

  # Get a runner token
  echo $(curl --request POST --silent \
    --url "${_TOKEN_ENDPOINT}" \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${app_token}" \
    --header "X-GitHub-Api-Version: 2022-11-28" | jq -r .token)
}

# Un-export these, so that they must be passed explicitly to the environment of
# any command that needs them. This may help prevent leaks.
export -n APP_CLIENT_ID
export -n APP_INSTALLATION_ID
export -n APP_PRIVATE_KEY

# Set the runner name
_RUNNER_NAME=${RUNNER_NAME:-${HOSTNAME}}
if [[ ! -z ${RUNNER_NAME_PREFIX} ]]; then
  _RUNNER_NAME=$(${RUNNER_NAME_PREFIX}-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13 ; echo ''))
fi
echo "Runner name: ${_RUNNER_NAME}"

_LABELS=${LABELS:-default}
_RUNNER_GROUP=${RUNNER_GROUP:-Default}
_EPHEMERAL=${EPHEMERAL:-true}
_DISABLE_AUTO_UPDATE=${DISABLE_AUTO_UPDATE:-true}

_RUNNER_WORKDIR=${RUNNER_WORKDIR:-/_work}
[[ ! -d "${_RUNNER_WORKDIR}" ]] && mkdir "${_RUNNER_WORKDIR}"

# Configure the URL and token endpoint based on the scope
_GITHUB_HOST=${GITHUB_HOST:="github.com"}
if [[ ${_GITHUB_HOST} = "github.com" ]]; then
  API_URI="https://api.${_GITHUB_HOST}"
else
  API_URI="https://${_GITHUB_HOST}/api/v3"
fi

if [[ -n ${REPO_URL} ]]; then
  _SHORT_URL=${REPO_URL}
  _TOKEN_ENDPOINT="$(echo "${_SHORT_URL}" | sed 's|'https://"${_GITHUB_HOST}"'|'"${API_URI}/repos"'|')/actions/runners/registration-token"
  RUNNER_SCOPE="repo"

elif [[ -n ${ORG_NAME} ]]; then
  _SHORT_URL="https://${_GITHUB_HOST}/${ORG_NAME}"
  _TOKEN_ENDPOINT="${API_URI}/orgs/${ORG_NAME}/actions/runners/registration-token"
  RUNNER_SCOPE="org"

elif [[ -n ${ENTERPRISE_NAME} ]]; then
  _SHORT_URL="https://${_GITHUB_HOST}/enterprises/${ENTERPRISE_NAME}"
  _TOKEN_ENDPOINT="${API_URI}/enterprises/${ENTERPRISE_NAME}/actions/runners/registration-token"
  RUNNER_SCOPE="enterprise"

else
  echo "ERROR: One of ENTERPRISE_NAME, ORG_NAME, or REPO_URL must be specified." >&2
  exit 1
fi
echo "Configuring runner for ${RUNNER_SCOPE}: ${_SHORT_URL}"

# Get a GitHub App token
if [[ -z ${APP_CLIENT_ID} ]]; then 
  echo "ERROR: APP_CLIENT_ID must be specified." >&2
  exit 1
fi
if [[ -z ${APP_INSTALLATION_ID} ]]; then 
  echo "ERROR: APP_INSTALLATION_ID must be specified." >&2
  exit 1
fi
if [[ -z ${APP_PRIVATE_KEY} ]]; then 
  echo "ERROR: APP_PRIVATE_KEY must be specified." >&2
  exit 1
fi
echo "Authenticating with GitHub App ${APP_CLIENT_ID} for installation ${APP_INSTALLATION_ID}"

# Configure the runner
ARGS=()
if [ -n "${_EPHEMERAL}" ]; then
  echo "Ephemeral option is enabled"
  ARGS+=("--ephemeral")
fi

if [ -n "${_DISABLE_AUTO_UPDATE}" ]; then
  echo "Disable auto update option is enabled"
  ARGS+=("--disableupdate")
fi

if [ -n "${NO_DEFAULT_LABELS}" ]; then
  echo "Disable adding the default self-hosted, platform, and architecture labels"
  ARGS+=("--no-default-labels")
fi

echo "Configuring runner"
./config.sh \
  --url "${_SHORT_URL}" \
  --token "$(get_runner_token)" \
  --name "${_RUNNER_NAME}" \
  --work "${_RUNNER_WORKDIR}" \
  --labels "${_LABELS}" \
  --runnergroup "${_RUNNER_GROUP}" \
  --unattended \
  --replace \
  "${ARGS[@]}"

echo "Configuring shutdown traps"
for sig in SIGINT SIGQUIT SIGTERM; do
  trap "deregister_runner ${sig}" "${sig}"
done

echo "Starting runner"
"$@"
