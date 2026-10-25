# ==========================================
# Stage 1: Build p9wl Compositor
# ==========================================
FROM alpine:latest AS builder
WORKDIR /app

RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
    gcompat \
    build-base \
    pkgconf \
    wlroots0.19-dev \
    wayland-dev \
    wayland-protocols \
    libxkbcommon-dev \
    pixman-dev \
    openssl-dev \
    fftw-dev \
    lz4-dev \
    zlib-dev \
    xkeyboard-config \
    linux-headers \
    openssl \
    git \
    libxi-dev \
    libxcursor-dev \
    libxinerama-dev \
    libxrandr-dev \
    mesa-dev \
    eudev-dev

COPY . .
RUN ln -s src/types.h types.h || true
RUN make clean && make


# ==========================================
# Stage 2: Download Official Godot Linux Binary (Auto-Detects ARM64 / x86_64)
# ==========================================
FROM alpine:latest AS godot-builder
WORKDIR /godot_src

RUN apk add --no-cache curl wget unzip

RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
        echo "Downloading Godot for Linux ARM64..." && \
        wget https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_linux.arm64.zip && \
        unzip Godot_v4.3-stable_linux.arm64.zip && \
        mv Godot_v4.3-stable_linux.arm64 /usr/local/bin/godot; \
    else \
        echo "Downloading Godot for Linux x86_64..." && \
        wget https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip && \
        unzip Godot_v4.3-stable_linux.x86_64.zip && \
        mv Godot_v4.3-stable_linux.x86_64 /usr/local/bin/godot; \
    fi


# ==========================================
# Stage 3: Package Export Container (Debian with fontconfig)
# ==========================================
FROM debian:stable-slim
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    fontconfig \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/p9wl-alpine /app/p9wl-alpine
COPY --from=godot-builder /usr/local/bin/godot /app/godot

# Create Godot project files inside container
RUN mkdir -p /app/godot_project/scripts

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

RUN cat << 'EOF' > /app/godot_project/main.tscn
[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/main.gd" id="1_script"]
[node name="Node2D" type="Node2D"]
script = ExtResource("1_script")
EOF

RUN cat << 'EOF' > /app/godot_project/scripts/main.gd
extends Node2D

var pos1 := Vector2(400, 400)
var speed1 := 300.0
var pos2 := Vector2(880, 400)
var speed2 := 300.0

func _process(delta: float) -> void:
    var dir1 := Vector2.ZERO
    if Input.is_key_pressed(KEY_W): dir1.y -= 1.0
    if Input.is_key_pressed(KEY_S): dir1.y += 1.0
    if Input.is_key_pressed(KEY_A): dir1.x -= 1.0
    if Input.is_key_pressed(KEY_D): dir1.x += 1.0
    pos1 += dir1.normalized() * speed1 * delta
    pos1.x = clamp(pos1.x, 40, 1240)
    pos1.y = clamp(pos1.y, 40, 760)

    var dir2 := Vector2.ZERO
    if Input.is_key_pressed(KEY_UP):    dir2.y -= 1.0
    if Input.is_key_pressed(KEY_DOWN):  dir2.y += 1.0
    if Input.is_key_pressed(KEY_LEFT):  dir2.x -= 1.0
    if Input.is_key_pressed(KEY_RIGHT): dir2.x += 1.0
    pos2 += dir2.normalized() * speed2 * delta
    pos2.x = clamp(pos2.x, 40, 1240)
    pos2.y = clamp(pos2.y, 40, 760)

    queue_redraw()

func _draw() -> void:
    draw_rect(Rect2(0, 0, 1280, 800), Color(0.06, 0.09, 0.16))
    draw_circle(pos1, 40, Color(0.3, 0.85, 1.0))
    draw_circle(pos2, 40, Color(1.0, 0.55, 0.2))
EOF

# Corrected export preset with platform="Linux/X11"
RUN cat << 'EOF' > /app/godot_project/export_presets.cfg
[preset.0]
name="Linux"
platform="Linux/X11"
runnable=true
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path="../game.pck"
encryption_include_filters=""
encryption_exclude_filters=""
encrypt_pck=false
encrypt_directory=false

[preset.0.options]
custom_template/debug=""
custom_template/release=""
EOF

# Export package script referencing "Linux" and triggering an import pass first
RUN cat << 'EOF' > /app/export_bundle.sh
#!/bin/sh
set -e

SHARED_DIR="/mnt/shared"
mkdir -p "$SHARED_DIR"

cd /app/godot_project

echo "Initializing project cache and importing assets..."
/app/godot --headless --editor --quit || true

echo "Packaging Godot project data..."
/app/godot --headless --export-pack "Linux" /app/game.pck

cd /app
echo "Copying artifacts to shared volume..."
cp /app/p9wl-alpine "$SHARED_DIR/p9wl-alpine"
cp /app/godot "$SHARED_DIR/godot-runtime"
cp /app/game.pck "$SHARED_DIR/game.pck"

echo "Build complete! Artifacts available in shared volume."
EOF

RUN chmod +x /app/export_bundle.sh
VOLUME /mnt/shared
ENTRYPOINT ["/app/export_bundle.sh"]