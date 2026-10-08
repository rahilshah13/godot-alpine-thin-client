1. `docker build -t p9wl-rdp .`
2. `docker run -itd --security-opt seccomp=unconfined -p 3389:3389 -p 8080:8080 p9wl-rdp`
3. localhost:8080

<img width="1438" height="992" alt="image" src="https://github.com/user-attachments/assets/7faae501-2a6b-47be-b624-8090a472387f" />


forked from: `https://github.com/maksym-radziwill/p9wl`