# --- Build Stage for p9wl ---
FROM alpine:latest AS builder
WORKDIR /app

RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
    build-base \
    pkgconf \
    wlroots0.19-dev \
    wayland-dev \
    wayland-protocols \
    libxkbcommon-dev \
    pixman-dev \
    freerdp-dev \
    openssl-dev \
    fftw-dev \
    lz4-dev \
    zlib-dev \
    xkeyboard-config \
    linux-headers \
    openssl \
    scons \
    git \
    libxi-dev \
    libxcursor-dev \
    libxinerama-dev \
    libxrandr-dev \
    mesa-dev \
    eudev-dev

COPY . .
RUN openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /app/server.key \
    -out /app/server.crt \
    -days 365 -subj "/CN=p9wl"

RUN ln -s src/types.h types.h || true
RUN make

# Clone Godot 4.3, patch missing <cstdint>, and build with use_lto=none and -U_FORTIFY_SOURCE to bypass musl/GCC 15 fortify inlining errors
RUN git clone --branch 4.3-stable --depth 1 https://github.com/godotengine/godot.git /godot_src
WORKDIR /godot_src
RUN sed -i '/#include <unordered_map>/a #include <cstdint>' thirdparty/glslang/SPIRV/SpvBuilder.h
RUN sed -i '/#include <list>/a #include <cstdint>' thirdparty/thorvg/inc/thorvg.h
RUN scons platform=linuxbsd target=editor dev_build=no production=yes use_lto=none lto=none CCFLAGS="-U_FORTIFY_SOURCE" -j4

# --- Runtime & Web Frontend Stage ---
FROM alpine:latest

RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
    wlroots0.19 \
    wayland \
    libxkbcommon \
    pixman \
    freerdp \
    openssl \
    fftw \
    lz4 \
    zlib \
    xkeyboard-config \
    ttf-dejavu \
    ttf-liberation \
    fontconfig \
    nodejs \
    npm \
    mesa-gl \
    mesa-gles \
    libxi \
    libxcursor \
    libxinerama \
    libxrandr \
    eudev

WORKDIR /app
COPY --from=builder /app/p9wl-rdp-alpine /app/p9wl-rdp-alpine
COPY --from=builder /app/server.crt /app/server.crt
COPY --from=builder /app/server.key /app/server.key
COPY --from=builder /godot_src/bin/godot.linuxbsd.editor.arm64 /usr/local/bin/godot

RUN chmod 600 /app/server.key && chmod 644 /app/server.crt

ENV WLOG_LEVEL=TRACE
RUN mkdir -p /tmp/xdg
ENV XDG_RUNTIME_DIR=/tmp/xdg \
    WAYLAND_DISPLAY=wayland-0

# Create flat directory for Godot .gd scripts and inline scaffolding configuration files
RUN mkdir -p /app/godot_project/scripts

# 1. Inline project.godot
RUN cat << 'EOF' > /app/godot_project/project.godot
[application]
config/name="GodotKioskApp"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.3", "Forward Plus")

[display]
window/size/viewport_width=1280
window/size/viewport_height=800
window/size/fullscreen=true
window/vsync/vsync_mode=0

[rendering]
environment/defaults/default_clear_color=Color(0.06, 0.09, 0.16, 1)
EOF

# 2. Inline main.tscn scene file
RUN cat << 'EOF' > /app/godot_project/main.tscn
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/main.gd" id="1_script"]

[node name="Node2D" type="Node2D"]
script = ExtResource("1_script")
EOF

# 3. Inline main.gd script
RUN cat << 'EOF' > /app/godot_project/scripts/main.gd
extends Node2D

var pos := Vector2(640, 400)
var vel := Vector2(240, 180)

func _process(delta: float) -> void:
	pos += vel * delta
	if pos.x < 100 or pos.x > 1180:
		vel.x *= -1
	if pos.y < 100 or pos.y > 700:
		vel.y *= -1
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(0, 0, 1280, 800), Color(0.06, 0.09, 0.16))
	draw_circle(pos, 40, Color(0.3, 0.85, 1.0))
EOF

# --- Web Frontend Setup with Deflate Compressed Frame Streaming ---
RUN mkdir -p /app/web
WORKDIR /app/web
RUN npm init -y && npm install express ws

RUN cat << 'EOF' > server.js
const express = require('express');
const http = require('http');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { WebSocketServer } = require('ws');

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true });

const PORT = process.env.PORT || 8080;

app.get('/', (req, res) => {
    res.send(`<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>p9wl Live Viewer</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f8fafc; color: #0f172a; margin: 0; padding: 10px; display: flex; flex-direction: column; align-items: center; height: 100vh; box-sizing: border-box; outline: none; }
        .main-layout { width: 100%; max-width: 1400px; height: 100%; display: flex; flex-direction: column; gap: 8px; }
        header { display: flex; justify-content: space-between; align-items: center; padding: 4px 8px; background: #ffffff; border: 1px solid #e2e8f0; border-radius: 6px; font-size: 0.85rem; }
        h1 { color: #0284c7; margin: 0; font-size: 1rem; }
        .screen-container { flex-grow: 1; position: relative; background: #000000; border-radius: 6px; overflow: hidden; display: flex; justify-content: center; align-items: center; border: 1px solid #cbd5e1; min-height: 0; }
        canvas { width: 100%; height: 100%; object-fit: contain; display: block; cursor: crosshair; }
        .toolbar { display: flex; justify-content: space-between; align-items: center; background: #ffffff; padding: 6px 12px; border-radius: 6px; border: 1px solid #e2e8f0; font-size: 0.85rem; }
        button { background: #0284c7; color: white; border: none; padding: 4px 12px; border-radius: 4px; font-weight: 600; cursor: pointer; font-size: 0.85rem; }
        button:hover { background: #0369a1; }
        .status { display: inline-block; width: 8px; height: 8px; background: #eab308; border-radius: 50%; margin-right: 4px; }
        .status.connected { background: #22c55e; }
        .status.disconnected { background: #ef4444; }
        .meta { color: #64748b; font-family: monospace; font-size: 0.8rem; }
    </style>
</head>
<body tabindex="0">
    <div class="main-layout">
        <header>
            <h1>p9wl</h1>
            <div><span id="status-dot" class="status"></span><span id="status-text" class="meta">Connecting...</span></div>
        </header>
        
        <div class="screen-container">
            <canvas id="rdpCanvas" width="1280" height="800"></canvas>
        </div>
        
        <div class="toolbar">
            <button id="playPauseBtn" onclick="togglePlayPause()">Pause</button>
            <div class="meta">Frame: <span id="frameNumLabel">--</span></div>
        </div>
    </div>

    <script>
        const canvas = document.getElementById('rdpCanvas');
        const ctx = canvas.getContext('2d');
        const statusDot = document.getElementById('status-dot');
        const statusText = document.getElementById('status-text');

        let isPlaying = true;
        let latestBuffer = null;
        let latestFrameNum = '--';

        function drawPlaceholder(text) {
            ctx.fillStyle = '#0f172a';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            ctx.fillStyle = '#38bdf8';
            ctx.font = '16px sans-serif';
            ctx.textAlign = 'center';
            ctx.fillText(text, canvas.width / 2, canvas.height / 2);
        }

        drawPlaceholder('Waiting for frames...');

        const ws = new WebSocket((location.protocol === 'https:' ? 'wss:' : 'ws:') + '//' + location.host + '/frame-stream');
        ws.binaryType = 'arraybuffer';

        ws.onopen = () => {
            statusDot.className = 'status connected';
            statusText.innerText = 'Live';
        };

        ws.onclose = () => {
            statusDot.className = 'status disconnected';
            statusText.innerText = 'Disconnected';
            drawPlaceholder('Connection lost');
        };

        ws.onmessage = async (event) => {
            const view = new DataView(event.data);
            const nameLen = view.getUint32(0);
            const nameBytes = new Uint8Array(event.data, 4, nameLen);
            const frameName = new TextDecoder().decode(nameBytes);
            const compressedBuffer = event.data.slice(4 + nameLen);

            try {
                const ds = new DecompressionStream('deflate');
                const decompressedStream = new Response(compressedBuffer).body.pipeThrough(ds);
                const ppmBuffer = await new Response(decompressedStream).arrayBuffer();

                const match = frameName.match(/frame_(\\d+)\\.ppm/);
                latestFrameNum = match ? match[1] : frameName;
                latestBuffer = ppmBuffer;

                if (isPlaying) {
                    renderPPM(latestBuffer, latestFrameNum);
                }
            } catch (err) {}
        };

        function renderPPM(arrayBuffer, frameNum) {
            const bytes = new Uint8Array(arrayBuffer);
            let text = new TextDecoder().decode(bytes.subarray(0, 200));
            let match = text.match(/^P6\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s/);
            if (!match) return;

            let w = parseInt(match[1]);
            let h = parseInt(match[2]);
            let headerLen = match[0].length;

            if (canvas.width !== w || canvas.height !== h) {
                canvas.width = w;
                canvas.height = h;
            }

            let pixelData = bytes.subarray(headerLen);
            let imgData = ctx.createImageData(w, h);
            let data = imgData.data;

            let p = 0;
            let q = 0;
            let totalPixels = w * h;
            for (let i = 0; i < totalPixels; i++) {
                data[q]     = pixelData[p];     
                data[q + 1] = pixelData[p + 1]; 
                data[q + 2] = pixelData[p + 2]; 
                data[q + 3] = 255;              
                p += 3;
                q += 4;
            }

            ctx.putImageData(imgData, 0, 0);
            document.getElementById('frameNumLabel').innerText = frameNum;
        }

        function sendInput(type, data) {
            if (ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({ type, ...data }));
            }
        }

        canvas.addEventListener('mousemove', (e) => {
            const rect = canvas.getBoundingClientRect();
            const x = Math.floor((e.clientX - rect.left) * (canvas.width / rect.width));
            const y = Math.floor((e.clientY - rect.top) * (canvas.height / rect.height));
            sendInput('mouse', { x, y, buttons: e.buttons });
        });

        canvas.addEventListener('mousedown', (e) => {
            const rect = canvas.getBoundingClientRect();
            const x = Math.floor((e.clientX - rect.left) * (canvas.width / rect.width));
            const y = Math.floor((e.clientY - rect.top) * (canvas.height / rect.height));
            let btnMask = e.button === 0 ? 1 : (e.button === 2 ? 4 : 2);
            sendInput('mouse', { x, y, buttons: btnMask });
        });

        canvas.addEventListener('mouseup', (e) => {
            const rect = canvas.getBoundingClientRect();
            const x = Math.floor((e.clientX - rect.left) * (canvas.width / rect.width));
            const y = Math.floor((e.clientY - rect.top) * (canvas.height / rect.height));
            sendInput('mouse', { x, y, buttons: 0 });
        });

        const codeToEvdev = {
            'KeyA': 30, 'KeyB': 48, 'KeyC': 46, 'KeyD': 32, 'KeyE': 18, 'KeyF': 33, 'KeyG': 34,
            'KeyH': 35, 'KeyI': 23, 'KeyJ': 36, 'KeyK': 37, 'KeyL': 38, 'KeyM': 50, 'KeyN': 49,
            'KeyO': 24, 'KeyP': 25, 'KeyQ': 16, 'KeyR': 19, 'KeyS': 31, 'KeyT': 20, 'KeyU': 22,
            'KeyV': 47, 'KeyW': 17, 'KeyX': 45, 'KeyY': 21, 'KeyZ': 44,
            'Digit1': 2, 'Digit2': 3, 'Digit3': 4, 'Digit4': 5, 'Digit5': 6,
            'Digit6': 7, 'Digit7': 8, 'Digit8': 9, 'Digit9': 10, 'Digit0': 11,
            'Space': 57, 'Enter': 28, 'Backspace': 14, 'Escape': 1, 'Tab': 15,
            'ArrowUp': 103, 'ArrowDown': 108, 'ArrowLeft': 105, 'ArrowRight': 106
        };

        window.addEventListener('keydown', (e) => {
            const scancode = codeToEvdev[e.code] || e.keyCode;
            sendInput('key', { rune: scancode, pressed: 1 });
        });

        window.addEventListener('keyup', (e) => {
            const scancode = codeToEvdev[e.code] || e.keyCode;
            sendInput('key', { rune: scancode, pressed: 0 });
        });

        function togglePlayPause() {
            isPlaying = !isPlaying;
            const btn = document.getElementById('playPauseBtn');
            btn.innerText = isPlaying ? 'Pause' : 'Play';
            if (isPlaying && latestBuffer) {
                renderPPM(latestBuffer, latestFrameNum);
            }
        }
    </script>
</body>
</html>`);
});

server.on('upgrade', (request, socket, head) => {
    if (request.url === '/frame-stream') {
        wss.handleUpgrade(request, socket, head, (ws) => {
            wss.emit('connection', ws, request);
        });
    } else {
        socket.destroy();
    }
});

wss.on('connection', (ws) => {
    ws.on('message', (message) => {
        try {
            const msg = JSON.parse(message);
            let line = '';
            if (msg.type === 'mouse') {
                line = `MOUSE ${msg.x} ${msg.y} ${msg.buttons}\n`;
            } else if (msg.type === 'key') {
                line = `KEY ${msg.rune} ${msg.pressed}\n`;
            }
            if (line) {
                fs.appendFile('/tmp/p9wl_input.fifo', line, (err) => {});
            }
        } catch (e) {}
    });
});

setInterval(() => {
    try {
        const files = fs.readdirSync('/app')
            .filter(f => f.startsWith('frame_') && f.endsWith('.ppm'))
            .map(f => ({ name: f, time: fs.statSync(path.join('/app', f)).mtime.getTime(), path: path.join('/app', f) }))
            .sort((a, b) => b.time - a.time);

        if (files.length > 0) {
            const latest = files[0];
            const ppmBuffer = fs.readFileSync(latest.path);
            const compressedBuffer = zlib.deflateSync(ppmBuffer);

            const nameBytes = Buffer.from(latest.name, 'utf-8');
            const header = Buffer.alloc(4);
            header.writeUInt32BE(nameBytes.length, 0);
            const payload = Buffer.concat([header, nameBytes, compressedBuffer]);

            wss.clients.forEach(client => {
                if (client.readyState === client.OPEN) {
                    client.send(payload);
                }
            });

            for (let i = 1; i < files.length; i++) {
                try { fs.unlinkSync(files[i].path); } catch (e) {}
            }
        }
    } catch (e) {}
}, 20);

server.listen(PORT, '0.0.0.0', () => {
    console.log('Live server running on http://0.0.0.0:' + PORT);
});
EOF

# --- Entrypoint & Wrapper ---
WORKDIR /app
RUN cat << 'EOF' > /app/run_godot.sh
#!/bin/sh
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export WLR_RENDERER=pixman
export WLR_BACKENDS=headless
exec godot --path /app/godot_project --display-driver wayland --rendering-driver opengl3
EOF

RUN chmod +x /app/run_godot.sh

RUN cat << 'EOF' > /app/entrypoint.sh
#!/bin/sh
/app/p9wl-rdp-alpine -d "/app/run_godot.sh" &
node /app/web/server.js
EOF

RUN chmod +x /app/entrypoint.sh
EXPOSE 3389 8080
ENTRYPOINT ["/app/entrypoint.sh"]