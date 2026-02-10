#!/bin/bash
set -euo pipefail

# Multi-arch patch build script for px4-gazebo-headless
# Layers updated scripts/worlds on top of an existing base image
# Builds for linux/amd64 (Windows+WSL) and linux/arm64 (macOS Apple Silicon)
#
# Usage:
#   ./build.sh                        # Build without pushing (validate only)
#   ./build.sh --push                 # Build and push to ECR
#   ./build.sh --tag my-tag --push    # Custom tag
#   ./build.sh --base <image> --push  # Custom base image
#
# Prerequisites:
#   - AWS credentials (aws sso login or similar)
#   - Docker with buildx support

ECR_REGISTRY="381491823703.dkr.ecr.us-east-1.amazonaws.com"
ECR_REPO="${ECR_REGISTRY}/gz-harmonic-headless"
PLATFORMS="linux/amd64,linux/arm64"
BUILDER_NAME="multiarch"

# Defaults
BASE_IMAGE="${ECR_REPO}:gz-harmonic.px4-02103b9100.7fedb94"
REPO_COMMIT=$(git rev-parse --short HEAD)
TAG=""
PUSH=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --push) PUSH=true; shift ;;
        --tag) TAG="$2"; shift 2 ;;
        --base) BASE_IMAGE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Extract PX4 commit from base image tag for the output tag
PX4_COMMIT=$(echo "${BASE_IMAGE}" | grep -oP 'px4-\K[^.]+' || echo "unknown")
TAG="${TAG:-gz-harmonic.px4-${PX4_COMMIT}.${REPO_COMMIT}}"
FULL_IMAGE="${ECR_REPO}:${TAG}"

echo "Base image: ${BASE_IMAGE}"
echo "Output:     ${FULL_IMAGE}"
echo "Platforms:  ${PLATFORMS}"
echo "Push:       ${PUSH}"
echo ""

# Verify AWS credentials are valid (ECR auth is handled by the ecr-login credential helper)
echo "Checking AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERROR: AWS credentials are expired or missing. Run 'aws sso login' and try again."
    exit 1
fi

# Ensure buildx builder exists
if ! docker buildx inspect "${BUILDER_NAME}" &>/dev/null; then
    echo "Creating buildx builder '${BUILDER_NAME}'..."
    docker buildx create --name "${BUILDER_NAME}" --use
else
    docker buildx use "${BUILDER_NAME}"
fi

echo ""
echo "Starting multi-arch build..."
echo ""

BUILD_ARGS=(
    --platform "${PLATFORMS}"
    --tag "${FULL_IMAGE}"
    --build-arg "BASE_IMAGE=${BASE_IMAGE}"
    -f Dockerfile.patch
)

if [ "$PUSH" = true ]; then
    BUILD_ARGS+=(--push)
else
    echo "NOTE: Multi-arch images can't be loaded locally. Use --push to push to ECR."
    echo "      Building to validate only (layers will be cached for subsequent --push)."
    echo ""
fi

docker buildx build "${BUILD_ARGS[@]}" .

echo ""
echo "Done! Image: ${FULL_IMAGE}"

if [ "$PUSH" = true ]; then
    echo ""
    echo "Verify with:"
    echo "  docker buildx imagetools inspect ${FULL_IMAGE}"
else
    echo ""
    echo "To push to ECR, run:"
    echo "  ./build.sh --push"
fi
