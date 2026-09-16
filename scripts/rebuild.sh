#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${1:-${PROJECT_ROOT}/artifacts/rebuild-${STAMP}}"
WORK_DIR="$(mktemp -d -p "${PROJECT_ROOT}" .rebuild-work.XXXXXX)"

CLIENT_REPO="https://github.com/bropat/eufy-security-client.git"
CLIENT_TAG="4.1.0"
CLIENT_COMMIT="10155f572a0f261acb207c76edc17e2cae78de90"
CLIENT_VERSION="4.1.0-pr975.1"
PR_PATCH_SHA256="2b7dd562d4186823f74eac46869f1ed7dfb6c09e2a7559c31866be3fbef09709"

WS_REPO="https://github.com/bropat/eufy-security-ws.git"
WS_TAG="3.1.0"
WS_COMMIT="e4709320f4e01e976ee65d53e763b6a656f0137d"
WS_VERSION="3.1.0-pr975.1"

NODE_IMAGE="node:24-alpine@sha256:e67514e5d0f6c46656005e1b693b2ec9d52e80b641307de684d4a015ba7a4eaf"
AMD64_BASE="ghcr.io/home-assistant/amd64-base:3.23@sha256:322c4492f25f9c2ca04b0789101a44350c516f4d3cd928fca14847ef19668ede"
AARCH64_BASE="ghcr.io/home-assistant/aarch64-base:3.23@sha256:e81d9f268833456f9803da051fa95fd8fa4e1fad1f911dec1a489a18701a76f5"

IMAGE_TAG="local/eufy-security-ws-pr975:${WS_VERSION}"
LOCAL_UID="$(id -u)"
LOCAL_GID="$(id -g)"

if [[ -e "${OUTPUT_DIR}" ]]; then
  echo "Refusing to overwrite existing output: ${OUTPUT_DIR}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

node_run() {
  local work_path="$1"
  shift
  docker run --rm \
    --user "${LOCAL_UID}:${LOCAL_GID}" \
    --env NPM_CONFIG_CACHE=/tmp/npm-cache \
    --volume "${work_path}:/work" \
    --workdir /work \
    "${NODE_IMAGE}" "$@"
}

CLIENT_DIR="${WORK_DIR}/eufy-security-client"
WS_DIR="${WORK_DIR}/eufy-security-ws"
ADDON_DIR="${OUTPUT_DIR}/eufy-security-ws-pr975"

git clone --depth 1 --branch "${CLIENT_TAG}" "${CLIENT_REPO}" "${CLIENT_DIR}"
test "$(git -C "${CLIENT_DIR}" rev-parse HEAD)" = "${CLIENT_COMMIT}"

echo "${PR_PATCH_SHA256}  ${PROJECT_ROOT}/patches/pr-975.patch" | sha256sum --check --status

git -C "${CLIENT_DIR}" apply --check "${PROJECT_ROOT}/patches/pr-975.patch"
git -C "${CLIENT_DIR}" apply "${PROJECT_ROOT}/patches/pr-975.patch"

git -C "${CLIENT_DIR}" apply --check "${PROJECT_ROOT}/patches/stream-timeout-15s.patch"
git -C "${CLIENT_DIR}" apply "${PROJECT_ROOT}/patches/stream-timeout-15s.patch"

node_run "${CLIENT_DIR}" npm pkg set \
  "version=${CLIENT_VERSION}" \
  "devDependencies.copyfiles=2.4.1"

node_run "${CLIENT_DIR}" npm install --package-lock-only --ignore-scripts
node_run "${CLIENT_DIR}" npm ci
node_run "${CLIENT_DIR}" npm run build

mkdir -p "${OUTPUT_DIR}/packages"

node_run "${CLIENT_DIR}" npm pack --ignore-scripts --pack-destination /work
mv "${CLIENT_DIR}/eufy-security-client-${CLIENT_VERSION}.tgz" "${OUTPUT_DIR}/packages/"

node_run "${CLIENT_DIR}" npm test -- --runInBand

git clone --depth 1 --branch "${WS_TAG}" "${WS_REPO}" "${WS_DIR}"
test "$(git -C "${WS_DIR}" rev-parse HEAD)" = "${WS_COMMIT}"

mkdir -p "${WS_DIR}/vendor"
cp "${OUTPUT_DIR}/packages/eufy-security-client-${CLIENT_VERSION}.tgz" "${WS_DIR}/vendor/"

node_run "${WS_DIR}" npm pkg set \
  "version=${WS_VERSION}" \
  "dependencies.eufy-security-client=file:vendor/eufy-security-client-${CLIENT_VERSION}.tgz"

node_run "${WS_DIR}" npm install --package-lock-only --ignore-scripts
node_run "${WS_DIR}" npm ci
node_run "${WS_DIR}" npm run build
node_run "${WS_DIR}" npm test -- --runInBand

mkdir -p "${ADDON_DIR}/app/vendor"

for file in Dockerfile config.yaml build.yaml run.sh apparmor.txt DOCS.md icon.png logo.png; do
  cp "${PROJECT_ROOT}/eufy-security-ws-pr975/${file}" "${ADDON_DIR}/${file}"
done

cp "${WS_DIR}/package.json" "${ADDON_DIR}/app/package.json"
cp "${WS_DIR}/package-lock.json" "${ADDON_DIR}/app/package-lock.json"
cp -a "${WS_DIR}/dist" "${ADDON_DIR}/app/dist"
cp "${WS_DIR}/vendor/eufy-security-client-${CLIENT_VERSION}.tgz" "${ADDON_DIR}/app/vendor/"

case "$(uname -m)" in
  x86_64)
    BUILD_FROM="${AMD64_BASE}"
    ;;
  aarch64|arm64)
    BUILD_FROM="${AARCH64_BASE}"
    ;;
  *)
    echo "Unsupported local image-build architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

docker build \
  --build-arg "BUILD_FROM=${BUILD_FROM}" \
  --tag "${IMAGE_TAG}" \
  "${ADDON_DIR}"

docker run --rm --network none \
  --entrypoint /usr/bin/node \
  "${IMAGE_TAG}" \
  -e "const a=require('/usr/src/app/node_modules/eufy-security-client/build/http/api.js'); if(!a.isSuccessfulResponseCode(0)||!a.isSuccessfulResponseCode(200)||a.isSuccessfulResponseCode(500)) process.exit(1);"

docker run --rm --network none \
  --entrypoint /usr/bin/node \
  "${IMAGE_TAG}" \
  /usr/src/app/node_modules/eufy-security-ws/dist/bin/server.js --help

tar -C "${OUTPUT_DIR}" \
  -czf "${OUTPUT_DIR}/eufy-security-ws-pr975-ha-addon.tar.gz" \
  eufy-security-ws-pr975

(
  cd "${OUTPUT_DIR}"
  sha256sum \
    "packages/eufy-security-client-${CLIENT_VERSION}.tgz" \
    "eufy-security-ws-pr975-ha-addon.tar.gz" \
    > SHA256SUMS
)

echo "Build completed."
echo "Preserved work directory: ${WORK_DIR}"
echo "Artifacts: ${OUTPUT_DIR}"
