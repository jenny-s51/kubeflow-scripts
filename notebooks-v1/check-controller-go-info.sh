#!/usr/bin/env bash
# Script to check Go version used to build any notebooks-v1 go-based controller binary
#
# Usage: check-controller-go-info.sh <controller-name> [namespace] [binary-path]
#
# Examples:
#   check-controller-go-info.sh notebook-controller
#   check-controller-go-info.sh pvcviewer-controller kubeflow
#   check-controller-go-info.sh tensorboard-controller kubeflow /manager
#
# Supported controllers:
#   - notebook-controller
#   - pvcviewer-controller
#   - tensorboard-controller

set -euo pipefail

# Function to print usage
usage() {
    cat <<EOF
Usage: $0 <controller-name> [namespace] [binary-path]

Check Go version and dependencies for a notebooks-v1 go-based controller.

Arguments:
  controller-name   Name of the controller (required)
                    Supported: notebook-controller, pvcviewer-controller, tensorboard-controller
  namespace         Kubernetes namespace (default: kubeflow)
  binary-path       Path to binary in container (default: /manager)

Examples:
  $0 notebook-controller
  $0 pvcviewer-controller kubeflow
  $0 tensorboard-controller kubeflow /manager
EOF
    exit 1
}

# Function to get app label for a controller
get_app_label() {
    local controller="$1"
    case "$controller" in
        notebook-controller)
            echo "notebook-controller"
            ;;
        pvcviewer-controller)
            echo "pvcviewer"
            ;;
        tensorboard-controller)
            echo "tensorboard-controller"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Function to get module pattern for a controller
get_module_pattern() {
    local controller="$1"
    case "$controller" in
        notebook-controller)
            echo "kubeflow.*notebook"
            ;;
        pvcviewer-controller)
            echo "kubeflow.*pvc-viewer"
            ;;
        tensorboard-controller)
            echo "kubeflow.*tensorboard"
            ;;
        *)
            echo "kubeflow"
            ;;
    esac
}

# Parse arguments
if [ $# -lt 1 ]; then
    usage
fi

CONTROLLER_NAME="$1"
NS="${2:-kubeflow}"
BINARY_PATH="${3:-/manager}"

# Validate controller name
APP_LABEL=$(get_app_label "$CONTROLLER_NAME")
if [ -z "$APP_LABEL" ]; then
    echo "Error: Unsupported controller: $CONTROLLER_NAME"
    echo ""
    echo "Supported controllers:"
    echo "  - notebook-controller"
    echo "  - pvcviewer-controller"
    echo "  - tensorboard-controller"
    exit 1
fi

# Get module pattern for this controller
MODULE_PATTERN=$(get_module_pattern "$CONTROLLER_NAME")

# Find pod
POD_NAME=$(kubectl get pods -n "$NS" -l app="$APP_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
    echo "Error: No $CONTROLLER_NAME pod found in namespace $NS"
    echo "Looking for pods with label: app=$APP_LABEL"
    exit 1
fi

echo "Controller: $CONTROLLER_NAME"
echo "Found pod: $POD_NAME"
IMAGE=$(kubectl get pod -n "$NS" "$POD_NAME" -o jsonpath='{.spec.containers[0].image}')
echo "Image: $IMAGE"
echo ""

# Extract binary from image
CONTAINER_NAME="temp-${CONTROLLER_NAME}-$$"
CONTAINER_ID=$(docker create --name "$CONTAINER_NAME" "$IMAGE" 2>/dev/null || echo "")
if [ -z "$CONTAINER_ID" ]; then
    echo "Error: Could not create container from image. Is the image available locally?"
    echo "Try: docker pull $IMAGE"
    exit 1
fi

TEMP_BINARY_PATH="/tmp/${CONTROLLER_NAME}-binary-$$"
if ! docker cp "${CONTAINER_NAME}:${BINARY_PATH}" "$TEMP_BINARY_PATH" 2>/dev/null; then
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1
    echo "Error: Failed to extract binary from path: $BINARY_PATH"
    echo "The binary might be at a different path in the container."
    exit 1
fi
docker rm "$CONTAINER_NAME" >/dev/null 2>&1

if [ ! -f "$TEMP_BINARY_PATH" ]; then
    echo "Error: Failed to extract binary"
    exit 1
fi

echo "=== Go Version Used to Build Binary ==="
go version -m "$TEMP_BINARY_PATH" 2>&1 | head -1

echo ""
echo "=== Main Module ==="
go version -m "$TEMP_BINARY_PATH" 2>&1 | grep "$MODULE_PATTERN" | sed 's/^[[:space:]]*dep[[:space:]]*/  /' || echo "  (not found)"

echo ""
echo "=== All Dependencies ==="
go version -m "$TEMP_BINARY_PATH" 2>&1 | grep "^[[:space:]]*dep" | sed 's/^[[:space:]]*dep[[:space:]]*/  /'

# Cleanup
rm -f "$TEMP_BINARY_PATH"
echo ""
echo "✓ Done"
