FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json server.js ./
USER node
EXPOSE 3001
CMD ["node", "server.js"]
