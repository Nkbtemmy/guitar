#!/usr/bin/env bash
# Rebuild all generated content: lesson text, video scripts (both by local Qwen) and the videos.
# Every stage is cached, so only what changed is regenerated.
#
#   tools/build_content.sh            # everything
#   tools/build_content.sh --force    # ignore caches
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x tools/.venv/bin/python ]; then
  python3 -m venv tools/.venv
  tools/.venv/bin/pip install -q pillow numpy
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg missing: brew install ffmpeg"; exit 1; }
curl -sf http://localhost:11434/api/version >/dev/null || { echo "Ollama is not running (needed for manzi-14b)"; exit 1; }

echo "1/4 lesson text (Qwen)";   python3 tools/qwen_content.py "$@"
echo "2/4 video scripts (Qwen)"; python3 tools/video_script.py "$@"
echo "3/4 videos";               tools/.venv/bin/python tools/video_render.py "$@"
echo "4/4 checks";               flutter test test/content_test.dart test/video_and_tab_test.dart
