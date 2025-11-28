#!/bin/bash

# require sudo
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
    exit 1
fi

mkdir nginx/certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout nginx/certs/key.key -out nginx/certs/cert.crt -subj "/C=US/ST=GenericState/L=GenericCity/O=GenericOrg/OU=GenericUnit/CN=generichost.com/emailAddress=generic@example.com"