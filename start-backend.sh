#!/bin/bash

# John Backend Runner
# Starts the Python backend server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"

check_python() {
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    elif command -v python &> /dev/null; then
        PYTHON_CMD="python"
    else
        echo "Error: Python 3 not found"
        exit 1
    fi
}

check_venv() {
    if [ ! -d "$BACKEND_DIR/venv" ]; then
        echo "Creating virtual environment..."
        cd "$BACKEND_DIR"
        $PYTHON_CMD -m venv venv
        source venv/bin/activate
        pip install -e .
        cd "$SCRIPT_DIR"
    fi
}

check_env() {
    if [ ! -f "$BACKEND_DIR/.env" ]; then
        echo "Warning: .env file not found. Creating from example..."
        if [ -f "$BACKEND_DIR/.env.example" ]; then
            cp "$BACKEND_DIR/.env.example" "$BACKEND_DIR/.env"
            echo "Please edit $BACKEND_DIR/.env and add your OPENROUTER_API_KEY"
        fi
    fi
    
    # Also check for global env file
    if [ -f "$HOME/.john.env" ]; then
        export OPENROUTER_API_KEY=$(grep OPENROUTER_API_KEY "$HOME/.john.env" | cut -d'=' -f2)
    fi
}

start_backend() {
    echo "Starting John Agent Backend..."
    cd "$BACKEND_DIR"
    source venv/bin/activate
    uvicorn app.main:app --host 127.0.0.1 --port 8765 --reload
}

main() {
    check_python
    check_venv
    check_env
    start_backend
}

main "$@"