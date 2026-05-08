FROM python:3.11-alpine

ARG UNFURL_REF=2d2dac375433d2a7fbeede2d25c5f19b68d4d244

RUN apk update && apk add --no-cache git wget && \
    pip install --upgrade pip

RUN git clone https://github.com/RyanDFIR/unfurl /unfurl && \
    cd /unfurl && \
    git checkout 2d2dac375433d2a7fbeede2d25c5f19b68d4d244 && \
    pip install -r /unfurl/requirements.txt && \
    pip install -r /unfurl/requirements-ui.txt && \
    pip install -e /unfurl

WORKDIR /unfurl

EXPOSE 5000

ENTRYPOINT ["python", "-c", "from unfurl.app import web_app; web_app()"]
