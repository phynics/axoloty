ARG NODE_IMAGE=docker.io/library/node@sha256:9b60cdcee9c6a27227689ebf4e7dd422ff195e978ffec360db5c0b3a05e20452
FROM ${NODE_IMAGE}

WORKDIR /agent
COPY package.json package-lock.json ./
RUN npm ci --omit=optional
COPY scenario-runner.js ./
RUN chown -R node:node /agent && chmod 0444 /agent/scenario-runner.js

USER node
ENTRYPOINT ["node", "scenario-runner.js"]
