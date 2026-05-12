FROM node:20-alpine AS builder

ARG PARSEL_REF=730ce238a81357edcb07bfff91d0159de2556180

RUN apk add --no-cache git python3 make g++

WORKDIR /src

RUN git clone https://github.com/elder-plinius/P4RS3LT0NGV3.git . && \
    git checkout --detach ${PARSEL_REF} && \
    npm ci && \
    npm run build

FROM nginx:1.27-alpine

RUN cat > /etc/nginx/conf.d/default.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF

COPY --from=builder /src/dist/ /usr/share/nginx/html/

EXPOSE 80
