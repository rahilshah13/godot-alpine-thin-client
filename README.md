1. `docker build -t godot-thin-client .`
2. `docker run -itd --security-opt seccomp=unconfined -p 3389:3389 -p 8080:8080 godot-thin-client`
3. localhost:8080

<img width="1083" height="887" alt="image" src="https://github.com/user-attachments/assets/38aa102c-52b9-4d01-895e-a9aa21a36cf1" />

forked from: `https://github.com/maksym-radziwill/p9wl`, `https://github.com/rahilshah13/p9wl-rdp`