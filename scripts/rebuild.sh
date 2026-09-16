#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="${PROJECT_ROOT}/.work"
ARTIFACT_ROOT="${PROJECT_ROOT}/artifacts"

CLIENT_REPO="https://github.com/bropat/eufy-security-client.git"
CLIENT_TAG="4.1.0"
CLIENT_COMMIT="10155f572a0f261acb207c76edc17e2cae78de90"
CLIENT_VERSION="4.1.0-pr975.1"

WS_REPO="https://github.com/bropat/eufy-security-ws.git"
WS_TAG="3.1.0"
WS_COMMIT="6b93786e142e2b925012c83c20e4c575c1afc92a"
WS_VERSION="3.1.0-pr975.1"

PR_PATCH_SHA256="6a9dd81385ff38293ec88b2092380d83f417572da08763a12656b5d429fbfd5b"

CLIENT_DIR="${WORK_ROOT}/eufy-security-client"
WS_DIR="${WORK_ROOT}/eufy-security-ws"
ADDON_DIR="${WORK_ROOT}/eufy-security-ws-pr975"
BUILD_DATE="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${ARTIFACT_ROOT}/rebuild-${BUILD_DATE}"

rm -rf "${WORK_ROOT}"
mkdir -p "${WORK_ROOT}" "${OUTPUT_DIR}"

echo "==> Clone eufy-security-client ${CLIENT_TAG}"
git clone --depth 1 --branch "${CLIENT_TAG}" "${CLIENT_REPO}" "${CLIENT_DIR}"

ACTUAL_CLIENT_COMMIT="$(git -C "${CLIENT_DIR}" rev-parse HEAD)"
if [[ "${ACTUAL_CLIENT_COMMIT}" != "${CLIENT_COMMIT}" ]]; then
  echo "Unexpected eufy-security-client commit:"
  echo "Expected: ${CLIENT_COMMIT}"
  echo "Actual:   ${ACTUAL_CLIENT_COMMIT}"
  exit 1
fi

echo "==> Verify PR975 patch"
echo "${PR_PATCH_SHA256}  ${PROJECT_ROOT}/patches/pr-975.patch" | sha256sum -c -

echo "==> Apply PR975 patch"
git -C "${CLIENT_DIR}" apply --check "${PROJECT_ROOT}/patches/pr-975.patch"
git -C "${CLIENT_DIR}" apply "${PROJECT_ROOT}/patches/pr-975.patch"

echo "==> Change P2P stream startup timeout from 5 seconds to 15 seconds"
grep -Fq \
  'private readonly MAX_STREAM_DATA_WAIT = 5 * 1000;' \
  "${CLIENT_DIR}/src/p2p/session.ts"

sed -i \
  's/private readonly MAX_STREAM_DATA_WAIT = 5 \* 1000;/private readonly MAX_STREAM_DATA_WAIT = 15 * 1000;/' \
  "${CLIENT_DIR}/src/p2p/session.ts"

grep -Fq \
  'private readonly MAX_STREAM_DATA_WAIT = 15 * 1000;' \
  "${CLIENT_DIR}/src/p2p/session.ts"

echo "==> Build eufy-security-client"
docker run --rm \
  -v "${CLIENT_DIR}:/workspace" \
  -w /workspace \
  node:24-alpine \
  sh -c "
    set -e
    npm ci
    npm version '${CLIENT_VERSION}' --no-git-tag-version
    npm run build
    npm test
    npm pack
  "

CLIENT_TGZ="$(find "${CLIENT_DIR}" -maxdepth 1 -name 'eufy-security-client-*.tgz' -print -quit)"
if [[ -z "${CLIENT_TGZ}" ]]; then
  echo "Client package was not created"
  exit 1
fi

echo "==> Clone eufy-security-ws ${WS_TAG}"
git clone --depth 1 --branch "${WS_TAG}" "${WS_REPO}" "${WS_DIR}"

ACTUAL_WS_COMMIT="$(git -C "${WS_DIR}" rev-parse HEAD)"
if [[ "${ACTUAL_WS_COMMIT}" != "${WS_COMMIT}" ]]; then
  echo "Unexpected eufy-security-ws commit:"
  echo "Expected: ${WS_COMMIT}"
  echo "Actual:   ${ACTUAL_WS_COMMIT}"
  exit 1
fi

mkdir -p "${WS_DIR}/vendor"
cp "${CLIENT_TGZ}" "${WS_DIR}/vendor/eufy-security-client.tgz"

echo "==> Build eufy-security-ws"
docker run --rm \
  -v "${WS_DIR}:/workspace" \
  -w /workspace \
  node:24-alpine \
  sh -c "
    set -e
    npm ci
    npm install --save-exact ./vendor/eufy-security-client.tgz
    npm version '${WS_VERSION}' --no-git-tag-version
    npm run build
    npm test
  "

echo "==> Prepare Home Assistant add-on"
mkdir -p "${ADDON_DIR}/app/vendor"
cp "${PROJECT_ROOT}/eufy-security-ws-pr975/Dockerfile" "${ADDON_DIR}/Dockerfile"
cp "${PROJECT_ROOT}/eufy-security-ws-pr975/config.yaml" "${ADDON_DIR}/config.yaml"
cp "${PROJECT_ROOT}/eufy-security-ws-pr975/build.yaml" "${ADDON_DIR}/build.yaml"
cp "${PROJECT_ROOT}/eufy-security-ws-pr975/run.sh" "${ADDON_DIR}/run.sh"
cp "${PROJECT_ROOT}/eufy-security-ws-pr975/apparmor.txt" "${ADDON_DIR}/apparmor.txt"
cp "${PROJECT_ROOT}/eufy-security-ws-pr975/DOCS.md" "${ADDON_DIR}/DOCS.md"
cp "${PROJECT_ROOT}/eufy-security-ws-pr975/icon.png" "${ADDON_DIR}/icon.png"
cp "${PROJECT_ROOT}/eufy-security-ws-pr975/logo.png" "${ADDON_DIR}/logo.png"

cp "${WS_DIR}/package.json" "${ADDON_DIR}/app/package.json"
cp "${WS_DIR}/package-lock.json" "${ADDON_DIR}/app/package-lock.json"
cp -R "${WS_DIR}/dist" "${ADDON_DIR}/app/dist"
cp "${CLIENT_TGZ}" "${ADDON_DIR}/app/vendor/eufy-security-client.tgz"

echo "==> Build Home Assistant add-on images"

for ARCH in amd64 aarch64; do
  if [[ "${ARCH}" == "amd64" ]]; then
    BUILD_FROM="ghcr.io/home-assistant/amd64-base:3.23"
  else
    BUILD_FROM="ghcr.io/home-assistant/aarch64-base:3.23"
  fi

  IMAGE="local/eufy-security-ws-pr975:${WS_VERSION}-${ARCH}"

  docker build \
    --build-arg BUILD_FROM="${BUILD_FROM}" \
    -t "${IMAGE}" \
    "${ADDON_DIR}"

  echo "==> Smoke test ${ARCH}"
  docker run --rm \
    --entrypoint node \
    "${IMAGE}" \
    -e "
      const pkg = require('/usr/src/app/node_modules/eufy-security-ws/package.json');
      console.log(pkg.name, pkg.version);
    "
done

echo "==> Create artifacts"
cp -R "${ADDON_DIR}" "${OUTPUT_DIR}/eufy-security-ws-pr975"

tar -C "${OUTPUT_DIR}" \
  -czf "${OUTPUT_DIR}/eufy-security-ws-pr975-${WS_VERSION}.tar.gz" \
  eufy-security-ws-pr975

echo
echo "Build completed successfully."
echo "Artifacts:"
echo "${OUTPUT_DIR}"
