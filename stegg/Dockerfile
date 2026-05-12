FROM alpine:3.20 AS builder

ARG ST3GG_REF=7db09389507f90025e728a9516e155ebcf8dbeaf

RUN apk add --no-cache git

WORKDIR /src

RUN git clone https://github.com/elder-plinius/ST3GG.git . && \
    git checkout --detach ${ST3GG_REF} && \
    mkdir -p /site && \
    git archive --format=tar HEAD | tar -xf - -C /site

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

COPY --from=builder /site/ /usr/share/nginx/html/

EXPOSE 80
