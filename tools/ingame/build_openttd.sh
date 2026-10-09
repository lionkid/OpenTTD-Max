#!/bin/sh
# Build an OpenTTD release from source for QA (Ubuntu 24.04). Usage: tools/ingame/build_openttd.sh [tag] [prefix]
#   tools/ingame/build_openttd.sh 15.3 /opt/openttd-15.3
# Then: python3 tools/ingame/run.py --openttd /opt/openttd-15.3/build/openttd --grf-dir .
set -e
TAG=${1:-15.3}
DIR=${2:-/opt/openttd-$TAG}
apt-get install -y --no-install-recommends cmake ninja-build g++ pkg-config libsdl2-dev zlib1g-dev liblzma-dev \
    liblzo2-dev libpng-dev libfreetype-dev libfontconfig-dev libicu-dev libharfbuzz-dev libcurl4-openssl-dev \
    openttd-opengfx xvfb xdotool imagemagick grfcodec
[ -d "$DIR" ] || git clone --depth 1 --branch "$TAG" https://github.com/OpenTTD/OpenTTD.git "$DIR"
cmake -S "$DIR" -B "$DIR/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja -C "$DIR/build" openttd
