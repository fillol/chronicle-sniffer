FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:alpine

RUN apk add --no-cache \
        tshark      \
        procps      \
        iproute2

WORKDIR /app
RUN mkdir captures gcp-key

COPY sniffer_entrypoint.sh .
RUN chmod +x sniffer_entrypoint.sh

ENTRYPOINT ["/app/sniffer_entrypoint.sh"]