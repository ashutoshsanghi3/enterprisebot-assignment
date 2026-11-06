import os
import socket
from flask import Flask, jsonify

app = Flask(__name__)

@app.route('/')
def index():
    return jsonify({
        "app": os.getenv("APP_NAME", "unknown"),
        "version": os.getenv("VERSION", "unknown"),
        "pod": socket.gethostname()
    })

@app.route('/healthz')
def healthz():
    return "OK", 200

if __name__ == '__main__':
    # Run on 8080 to avoid low-port privileges
    app.run(host='0.0.0.0', port=8080)