"""Shared client for the local Qwen model (manzi-14b via Ollama) with a persistent prompt cache."""
import hashlib
import json
import os
import threading
import urllib.request

API = os.environ.get("OLLAMA_URL", "http://localhost:11434") + "/api/chat"
MODEL = os.environ.get("QWEN_MODEL", "manzi-14b")


def chat_json(system, user, schema, temperature=0.3, max_tokens=500):
    """One structured call; returns the parsed JSON object (or raises ValueError)."""
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "stream": False,
        "think": False,
        "format": schema,
        "options": {"temperature": temperature, "num_ctx": 6144, "num_predict": max_tokens},
    }).encode()
    req = urllib.request.Request(API, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=900) as r:
        content = json.loads(r.read())["message"]["content"]
    return json.loads(content)


class Cache:
    """Prompt-hash cache stored as JSON; safe to share between threads of one process."""

    def __init__(self, path, force=False):
        self.path = path
        self.force = force
        self._lock = threading.Lock()
        self.data = {} if force or not os.path.exists(path) else json.load(open(path))

    @staticmethod
    def key(*parts):
        return hashlib.sha1("\n".join([MODEL, *parts]).encode()).hexdigest()

    def get(self, key):
        return self.data.get(key)

    def put(self, key, value):
        with self._lock:
            self.data[key] = value
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.data, f, indent=1, ensure_ascii=False)
            os.replace(tmp, self.path)
