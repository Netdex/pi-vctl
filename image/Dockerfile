# Install tools here: apt fails inside a running vctl container, because its root
# filesystem is 9P and apt cannot verify signatures there. It works during vctl build.
FROM node:24-bookworm-slim
RUN apt-get -o APT::Sandbox::User=root update \
 && apt-get -o APT::Sandbox::User=root install -y --no-install-recommends bash ca-certificates fd-find git ripgrep \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*
# Every container start copies the whole image, file by file, so files that nothing loads
# are removed: npm's download cache, and type declarations, source maps and Markdown in
# dependencies. pi keeps its own Markdown and types, which it shows to the model.
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.0 \
 && npm cache clean --force \
 && cd /usr/local/lib/node_modules \
 && pi=@earendil-works/pi-coding-agent \
 && find "$pi/dist" -type f -name '*.map' -delete \
 && find . "$pi/node_modules" -path "./$pi" -prune -o -type f \
      \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' -o -name '*.md' -o -name '*.markdown' \) \
      -exec rm -f {} +
# See patch-shell.js. fd and rg are installed above so that pi does not download
# Linux binaries into the mounted ~/.pi/agent/bin, which the Windows host also uses.
COPY patch-shell.js /tmp/patch-shell.js
RUN node /tmp/patch-shell.js "$(npm root -g)/@earendil-works/pi-coding-agent" \
 && rm /tmp/patch-shell.js
# The two fixes for the TUI freeze: tty-newline.cjs is preloaded into pi, and the
# launcher runs agent-patch.sh in the VM. The sed keeps the script working if an
# editor saves it with CRLF line endings.
COPY tty-newline.cjs agent-patch.sh agent-patch.cjs /opt/pi-vctl/
RUN sed -i 's/\r$//' /opt/pi-vctl/agent-patch.sh
WORKDIR /workspace
ENTRYPOINT ["node", "--require", "/opt/pi-vctl/tty-newline.cjs", "/usr/local/bin/pi"]
