FROM oven/bun:1

# Install Python 3 + pip for LiteLLM proxy
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install LiteLLM proxy globally
RUN pip3 install --break-system-packages 'litellm[proxy]'

# Install gbrain globally from GitHub
RUN bun install -g github:garrytan/gbrain

# Copy LiteLLM config and anthropic shim
COPY litellm/config.yaml /etc/gbrain/litellm/config.yaml
COPY litellm/anthropic-shim.ts /etc/gbrain/litellm/anthropic-shim.ts

# Copy entrypoint
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Expose gbrain HTTP port (gbrain serve --http listens on 3131 by default)
EXPOSE 3131

# Default command: gbrain serve --http
CMD ["gbrain", "serve", "--http"]

ENTRYPOINT ["docker-entrypoint.sh"]
