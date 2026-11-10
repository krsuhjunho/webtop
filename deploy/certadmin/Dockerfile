FROM python:3.13-alpine

RUN apk add --no-cache openssl ca-certificates

COPY certadmin.py /app/certadmin.py

WORKDIR /app
USER root
EXPOSE 8080
CMD ["python", "-u", "/app/certadmin.py", "serve"]
