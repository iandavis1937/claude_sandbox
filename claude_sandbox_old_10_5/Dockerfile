FROM node:20-slim

# Create a non-root user for security
RUN useradd -m -u 1001 claude

# Install Claude Code globally via npm
RUN npm install -g @anthropic-ai/claude-code

# Set working directory and switch to non-root user
WORKDIR /workspace
USER claude

ENTRYPOINT ["claude"]