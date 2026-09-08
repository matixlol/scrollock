FROM node:22-alpine
WORKDIR /app
COPY --chown=node:node server/ ./server/
RUN mkdir -p /app/server/data && chown node:node /app/server/data
USER node
ENV NODE_ENV=production PORT=8787 HOST=0.0.0.0
EXPOSE 8787
CMD ["node", "server/index.mjs"]
