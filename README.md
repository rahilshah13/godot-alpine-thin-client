1. docker build -t p9wl-builder .
2. docker run --rm -v $(pwd)/dist:/mnt/shared p9wl-builder